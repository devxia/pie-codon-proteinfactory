import Foundation
import ProteinDomain
import ProteinPersistence
import ProteinService

public struct FirstSubmission: Sendable {
    let batch: Batch

    public init(confirmed preview: ProteinImportPreview) {
        self.init(confirmed: preview.batch)
    }

    public init(confirmed batch: Batch) {
        self.batch = batch
    }
}

public struct ConfirmedUnknownRetry: Sendable {
    let batchID: UUID
    let unknownRecords: [UUID: [UUID]]

    public init(confirmed batch: Batch) {
        batchID = batch.id
        unknownRecords = Self.unknownAttempts(in: batch)
    }

    static func unknownAttempts(in batch: Batch) -> [UUID: [UUID]] {
        batch.records.reduce(into: [:]) { result, record in
            if record.status == .unknown { result[record.id] = record.attempts.map(\.id) }
        }
    }
}

public enum QueueError: Error, Equatable, Sendable {
    case invalidSettings
    case capacityReached
    case duplicateSubmission
    case invalidPreparedBatch
    case missingBatch
    case staleRetryConfirmation
    case closed
    case storageFailure
}

public struct QueueSettings: Sendable {
    public let timeout: TimeInterval
    public let intervalMilliseconds: Int

    public init(timeout: TimeInterval = 120, intervalMilliseconds: Int = 500) throws {
        guard (1...120).contains(timeout), (100...10_000).contains(intervalMilliseconds) else {
            throw QueueError.invalidSettings
        }
        self.timeout = timeout
        self.intervalMilliseconds = intervalMilliseconds
    }
}

public actor QueueCoordinator {
    public static let maximumScheduledBatches = 10
    public static let maximumAuditBytes = 8 * 1024 * 1024

    private let store: ProteinStore
    private let service: any ProteinSubmissionService
    private let interval: Duration
    private let clock = ContinuousClock()
    private var nextDispatch: ContinuousClock.Instant?
    private var queued: [Batch] = []
    private var active: Batch?
    private var worker: Task<Void, Never>?
    private var delay: Task<Void, Never>?
    private var submission: Task<ProteinServiceReceipt, Never>?
    private var closed = false
    public private(set) var hasStorageFailure = false

    public init(store: ProteinStore, settings: QueueSettings) {
        self.init(store: store, service: ProteinServiceClient(timeout: settings.timeout), settings: settings)
    }

    init(store: ProteinStore, service: any ProteinSubmissionService, settings: QueueSettings) {
        self.store = store
        self.service = service
        interval = .milliseconds(settings.intervalMilliseconds)
    }

    public func submit(_ confirmation: FirstSubmission) throws {
        try checkCapacity()
        var batch = confirmation.batch
        guard batch.status == .prepared, batch.authorizedAt == nil, !batch.stopRequested, !batch.records.isEmpty,
              Set(batch.records.map(\.id)).count == batch.records.count,
              batch.records.allSatisfy({ $0.status == .pending && $0.attempts.isEmpty }) else {
            throw QueueError.invalidPreparedBatch
        }
        try PreviewIntegrity.verify(batch)
        let now = Date.now
        batch.authorizedAt = now
        batch.updatedAt = now
        batch.status = .queued
        if let existing = try write({ try store.batch(id: batch.id, includingResponses: false) }) {
            // A locally saved draft has no request attempts and is safe to authorize once.
            // Any other persisted state is a duplicate, never a new first submission.
            guard existing.status == .prepared, existing.authorizedAt == nil,
                  existing.requestID == confirmation.batch.requestID,
                  existing.name == confirmation.batch.name,
                  existing.parameters == confirmation.batch.parameters,
                  existing.endpoint == confirmation.batch.endpoint,
                  existing.fingerprint == confirmation.batch.fingerprint,
                  existing.records == confirmation.batch.records else {
                throw QueueError.duplicateSubmission
            }
            try write { try store.updateBatchMetadata([batch]) }
        } else {
            let inserted = try write { try store.insertNewBatch(batch) }
            guard inserted else { throw QueueError.duplicateSubmission }
        }
        schedule(batch)
    }

    public func retry(batchID: UUID) throws {
        try retry(batchID: batchID, confirmation: nil)
    }

    public func retry(_ confirmation: ConfirmedUnknownRetry) throws {
        try retry(batchID: confirmation.batchID, confirmation: confirmation)
    }

    public func stop(batchID: UUID) throws {
        try checkOpen()
        if var batch = active, batch.id == batchID {
            batch.stopRequested = true
            batch.updatedAt = .now
            try write { try store.updateBatchMetadata([batch]) }
            active = batch
            delay?.cancel()
        } else if let index = queued.firstIndex(where: { $0.id == batchID }) {
            let batch = stopped(queued[index], message: "stopped_by_user")
            try write { try store.updateBatchMetadata([batch]) }
            queued.remove(at: index)
            delay?.cancel()
        }
    }

    public func freezeForExit() throws {
        if closed { return }
        closed = true
        delay?.cancel()
        try stopQueued(message: "application_exiting")
        if var batch = active {
            batch.stopRequested = true
            batch.updatedAt = .now
            try write { try store.updateBatchMetadata([batch]) }
            active = batch
        }
    }

    public func cancelInFlightForExit() async throws {
        do {
            try freezeForExit()
        } catch {
            submission?.cancel()
            throw error
        }
        submission?.cancel()
        await waitUntilIdle()
        if hasStorageFailure { throw QueueError.storageFailure }
    }

    public func waitUntilIdle() async {
        await worker?.value
    }

    public var hasScheduledWork: Bool { active != nil || !queued.isEmpty }

    private func retry(batchID: UUID, confirmation: ConfirmedUnknownRetry?) throws {
        try checkCapacity()
        guard var batch = try store.batch(id: batchID) else { throw QueueError.missingBatch }
        if let confirmation {
            guard !confirmation.unknownRecords.isEmpty,
                  confirmation.unknownRecords == ConfirmedUnknownRetry.unknownAttempts(in: batch) else {
                throw QueueError.staleRetryConfirmation
            }
        }
        let plan = try RetryPolicy.plan(for: batch, intent: confirmation == nil ? .ordinary : .confirmedUnknownEffect)
        let retryIDs = Set(plan.recordIDsToRetry)
        for index in batch.records.indices where retryIDs.contains(batch.records[index].id) {
            // Preserve unknown effects if the confirmed retry stops before dispatch.
            if batch.records[index].status != .unknown {
                batch.records[index].status = .pending
                batch.records[index].error = nil
            }
            batch.records[index].dna = nil
            batch.records[index].dnaSHA256 = nil
            batch.records[index].checks = nil
        }
        batch.status = .queued
        batch.updatedAt = .now
        batch.stopRequested = false
        batch.message = ""
        try write { try store.saveBatch(batch) }
        schedule(batch)
    }

    private func schedule(_ batch: Batch) {
        let insertion = queued.firstIndex { $0.createdAt > batch.createdAt } ?? queued.endIndex
        queued.insert(batch, at: insertion)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    private func checkOpen() throws {
        if hasStorageFailure { throw QueueError.storageFailure }
        if closed { throw QueueError.closed }
    }

    private func checkCapacity() throws {
        try checkOpen()
        let activeCount = active == nil ? 0 : 1
        guard queued.count + activeCount < Self.maximumScheduledBatches else { throw QueueError.capacityReached }
    }

    private func write<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            hasStorageFailure = true
            closed = true
            delay?.cancel()
            throw QueueError.storageFailure
        }
    }

    private func drain() async {
        defer {
            if hasStorageFailure {
                // The next launch recovers the last committed dispatch and queued batches.
                active = nil
                queued.removeAll()
            }
            worker = nil
        }
        do {
            while !hasStorageFailure {
                if let batch = active, batch.stopRequested || nextRecord(in: batch) == nil {
                    try finish(batch)
                    continue
                }
                if active == nil && (closed || queued.isEmpty) { return }
                if let deadline = nextDispatch, clock.now < deadline {
                    let clock = self.clock
                    let delay = Task {
                        do { try await clock.sleep(until: deadline) } catch { return }
                    }
                    self.delay = delay
                    await delay.value
                    self.delay = nil
                    continue
                }
                if active == nil { try startNextBatch() }
                if let batch = active, let index = nextRecord(in: batch) {
                    try await sendRecord(at: index, in: batch)
                }
            }
        } catch {
            hasStorageFailure = true
            closed = true
        }
    }

    private func nextRecord(in batch: Batch) -> Int? {
        // Only an explicitly confirmed retry can put an unknown record in the live queue.
        batch.records.firstIndex { $0.status == .pending || $0.status == .unknown }
    }

    private func startNextBatch() throws {
        var batch = queued.removeFirst()
        batch.status = .running
        batch.updatedAt = .now
        try write { try store.updateBatchMetadata([batch]) }
        active = batch
    }

    private func sendRecord(at index: Int, in scheduled: Batch) async throws {
        var batch = scheduled
        var record = batch.records[index]
        let priorStatus = record.status
        guard try !ProteinStore.exceedsAuditBudget(batch, limit: Self.maximumAuditBytes) else {
            batch.stopRequested = true
            batch.message = "audit_budget_reached"
            try finish(batch)
            return
        }
        let previousNumber = record.attempts.last?.number ?? 0
        guard previousNumber < ProteinDomainLimits.maximumAttempts,
              record.attempts.count < ProteinDomainLimits.maximumAttempts else {
            batch.stopRequested = true
            batch.message = "attempt_limit_reached"
            try finish(batch)
            return
        }
        let request = try ProteinServiceRequest(record: record, parameters: batch.parameters)
        var attempt = RequestAttempt(number: previousNumber + 1, startedAt: .now, payloadSHA256: request.payloadSHA256)
        record.status = .running
        batch.updatedAt = attempt.startedAt
        try write { try store.saveAttempt(attempt, updatingRecord: record, updatingBatch: batch) }
        record.attempts.append(attempt)
        batch.records[index] = record
        active = batch

        let start = clock.now
        let service = self.service
        let submission = Task { await service.submit(request) }
        self.submission = submission
        let receipt = await submission.value
        self.submission = nil
        nextDispatch = clock.now.advanced(by: interval)
        if hasStorageFailure { return }

        // Stop or exit may have updated batch metadata while the request was in flight.
        guard var current = active else { throw QueueError.storageFailure }
        let outcome = receipt.outcome
        attempt.finishedAt = .now
        attempt.elapsedMilliseconds = Int(start.duration(to: clock.now) / .milliseconds(1))
        attempt.status = outcome.attemptStatus
        attempt.effect = outcome.effect
        attempt.httpStatus = outcome.httpStatus
        attempt.response = receipt.response
        attempt.error = outcome.auditError
        if priorStatus == .unknown, outcome.effect == .notSubmitted {
            record.status = .unknown
        } else {
            record.status = outcome.status
            record.error = attempt.error
        }
        record.attempts[record.attempts.count - 1] = attempt
        if case .completed(let dna, _) = outcome {
            record.dna = dna.dna
            record.dnaSHA256 = dna.sha256
            record.checks = dna.checks
        }
        current.records[index] = record
        current.updatedAt = attempt.finishedAt ?? .now
        if outcome.shouldStopQueue {
            current.stopRequested = true
            current.message = "service_paused_queue"
        }
        try write { try store.saveAttempt(attempt, updatingRecord: record, updatingBatch: current) }
        active = current
        if outcome.shouldStopQueue { try stopQueued(message: "service_paused_queue") }
    }

    private func finish(_ batch: Batch) throws {
        guard let status = BatchSummary(statuses: batch.records.map(\.status)).statusAfterExecution else {
            throw QueueError.storageFailure
        }
        var finished = batch
        finished.status = status
        finished.updatedAt = .now
        try write { try store.updateBatchMetadata([finished]) }
        active = nil
    }

    private func stopQueued(message: String) throws {
        guard !queued.isEmpty else { return }
        let stoppedBatches = queued.map { stopped($0, message: message) }
        try write { try store.updateBatchMetadata(stoppedBatches) }
        queued.removeAll()
    }

    private func stopped(_ batch: Batch, message: String) -> Batch {
        var batch = batch
        batch.status = .stopped
        batch.stopRequested = true
        batch.updatedAt = .now
        batch.message = message
        return batch
    }
}

private extension ServiceOutcome {
    var auditError: String? {
        switch self {
        case .completed: nil
        case .failed(let reason, _): String(describing: reason)
        case .rejected(let status): "http_\(status)"
        case .notSubmitted(let reason): String(describing: reason)
        case .unknown(let reason, _): String(describing: reason)
        }
    }
}
