import Foundation
import GRDB
@testable import ProteinApplication
import ProteinDomain
import ProteinPersistence
import ProteinService
import Testing

@Suite(.timeLimit(.minutes(1)))
struct QueueCoordinatorTests {
    @Test func firstSubmissionChecksPreviewIntegrityAndDeduplicatesRequestID() async throws {
        try await withQueue { queue, store, _, mock, events in
            var tampered = try prepared("Tampered preview", records: 2)
            tampered.records.reverse()
            let invalid = FirstSubmission(confirmed: tampered)
            await #expect(throws: PreviewIntegrityError.recordLayoutMismatch(position: 1)) {
                try await queue.submit(invalid)
            }
            #expect(try store.batch(id: tampered.id) == nil)
            #expect(await mock.count == 0)

            var calls = events.makeAsyncIterator()
            let first = try prepared("New preview", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            let duplicate = try BatchPreparation.prepare(name: "Duplicate request", input: .text("M"), requestID: first.requestID)
            await #expect(throws: QueueError.duplicateSubmission) { try await queue.submit(.init(confirmed: duplicate)) }
            #expect(try store.batch(id: duplicate.id) == nil)
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(await mock.count == 1)
        }
    }

    @Test func savedPreparedDraftIsAuthorizedOnceAndReceivesDNA() async throws {
        try await withQueue { queue, store, _, mock, events in
            let draft = try prepared("Saved draft", records: 1)
            #expect(try store.insertNewBatch(draft))
            #expect(try store.batch(id: draft.id)?.authorizedAt == nil)

            var calls = events.makeAsyncIterator()
            try await queue.submit(.init(confirmed: draft))
            _ = try #require(await calls.next())
            #expect(try store.batch(id: draft.id)?.status == .running)
            #expect(try store.batch(id: draft.id)?.authorizedAt != nil)
            await #expect(throws: QueueError.duplicateSubmission) {
                try await queue.submit(.init(confirmed: draft))
            }

            await mock.releaseFirst()
            await queue.waitUntilIdle()
            let completed = try #require(try store.batch(id: draft.id))
            #expect(completed.status == .completed)
            #expect(completed.records.first?.dna == "ATG")
            #expect(completed.records.first?.checks != nil)
            #expect(await mock.count == 1)
        }
    }

    @Test func serialDispatchPersistsExactPayloadAndReceiptBeforeNextRequest() async throws {
        try await withQueue { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("First", records: 2, time: 2)
            let earlier = try prepared("Earlier", records: 1, time: 1)
            let later = try prepared("Later", records: 1, time: 3)
            try await queue.submit(.init(confirmed: first))
            let firstCall = try #require(await calls.next())
            #expect(firstCall.batchID == first.id)
            #expect(firstCall.batchStatus == .running)
            #expect(firstCall.authorizedAt != nil)
            #expect(firstCall.record?.status == .running)
            #expect(firstCall.record?.attempts.first?.status == .dispatching)
            #expect(firstCall.record?.attempts.first?.effect == .unknown)
            #expect(firstCall.record?.attempts.first?.payloadSHA256 == firstCall.digest)
            try await queue.submit(.init(confirmed: later))
            try await queue.submit(.init(confirmed: earlier))
            await #expect(throws: QueueError.duplicateSubmission) { try await queue.submit(.init(confirmed: first)) }
            #expect(try store.batch(id: earlier.id)?.status == .queued)
            #expect(await mock.count == 1)
            await mock.releaseFirst()

            let next = try #require(await calls.next())
            #expect(next.batchID == first.id)
            #expect(next.position == 2)
            #expect(next.priorState?.attempts.first?.status == .completed)
            #expect(next.priorState?.attempts.first?.response == MockSubmission.goodResponse)
            #expect(next.priorState?.dnaSHA256 == .hash("ATG"))
            #expect(next.instant - firstCall.instant >= .milliseconds(100))
            #expect(await calls.next()?.batchID == earlier.id)
            #expect(await calls.next()?.batchID == later.id)
            await queue.waitUntilIdle()
            for batch in [first, earlier, later] { #expect(try store.batch(id: batch.id)?.status == .completed) }
            #expect(await mock.count == 4)
        }
    }

    @Test func stopLetsCurrentReceiptFinishAndThenContinuesOtherBatch() async throws {
        try await withQueue { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Stop me", records: 2)
            let second = try prepared("Keep going", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            try await queue.submit(.init(confirmed: second))
            try await queue.stop(batchID: first.id)
            #expect(try store.batch(id: first.id)?.stopRequested == true)
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(try store.batch(id: first.id)?.status == .stopped)
            #expect(try store.batch(id: first.id)?.records.map(\.status) == [.completed, .pending])
            #expect(try store.batch(id: second.id)?.status == .completed)
            #expect(await mock.count == 2)
        }
    }

    @Test(arguments: [ServiceOutcome.unknown(.missingSuccess, httpStatus: 200), .rejected(httpStatus: 429), .notSubmitted(.stopped)])
    func servicePauseStopsAllBatchesAndRequiresAppropriateRetry(outcome: ServiceOutcome) async throws {
        try await withQueue(firstOutcome: outcome) { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Service pause", records: 2)
            let second = try prepared("Queued", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            try await queue.submit(.init(confirmed: second))
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            let interrupted = try #require(try store.batch(id: first.id))
            #expect(interrupted.records.map(\.status) == [outcome.status, .pending])
            #expect(interrupted.records[0].attempts.first?.effect == outcome.effect)
            #expect(try store.batch(id: second.id)?.status == .stopped)
            #expect(try store.batch(id: second.id)?.records.first?.attempts.isEmpty == true)
            #expect(await mock.count == 1)
            if outcome.status == .unknown {
                await #expect(throws: RetryError.unknownEffectRequiresConfirmation) { try await queue.retry(batchID: first.id) }
                try await queue.retry(.init(confirmed: interrupted))
            } else {
                try await queue.retry(batchID: first.id)
            }
            await queue.waitUntilIdle()
            #expect(try store.batch(id: first.id)?.status == .completed)
            #expect(try store.batch(id: first.id)?.records[0].attempts.map(\.number) == [1, 2])
            #expect(try store.batch(id: second.id)?.status == .stopped)
            #expect(await mock.count == 3)
        }
    }

    @Test func stoppingConfirmedRetryBeforeDispatchDoesNotClearUnknownEffect() async throws {
        try await withQueue { queue, store, url, mock, events in
            var calls = events.makeAsyncIterator()
            let current = try prepared("In flight", records: 1)
            let retry = try historicalBatch("Unknown receipt", status: .unknown, attemptCount: 1)
            try store.saveBatch(retry)
            try await queue.submit(.init(confirmed: current))
            _ = try #require(await calls.next())
            try await queue.retry(.init(confirmed: retry))
            try await queue.stop(batchID: retry.id)
            await #expect(throws: RetryError.unknownEffectRequiresConfirmation) { try await queue.retry(batchID: retry.id) }
            #expect(try store.batch(id: retry.id)?.records[0].status == .unknown)
            try await queue.retry(.init(confirmed: retry))

            // Open a snapshot of the live database as a separate process would after interruption.
            let snapshot = url.deletingLastPathComponent().appendingPathComponent("snapshot.sqlite")
            let reader = try DatabaseQueue(path: url.path)
            let destination = try DatabaseQueue(path: snapshot.path)
            try reader.backup(to: destination)
            let reopened = try ProteinStore(url: snapshot)
            let restarted = QueueCoordinator(store: reopened, service: mock, settings: try testSettings())
            await restarted.waitUntilIdle()
            #expect(await mock.count == 1)
            let recovered = try #require(try reopened.batch(id: retry.id))
            #expect(recovered.status == .stopped)
            #expect(recovered.records[0].status == .unknown)
            #expect(recovered.records[0].attempts == retry.records[0].attempts)
            await #expect(throws: RetryError.unknownEffectRequiresConfirmation) { try await restarted.retry(batchID: retry.id) }

            try await queue.freezeForExit()
            await mock.releaseFirst()
            await queue.waitUntilIdle()
        }
    }

    @Test func refusedConfirmedRetryPreservesUnknownAndInvalidatesOldConfirmation() async throws {
        try await withQueue(firstOutcome: .notSubmitted(.cancelled)) { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let retry = try historicalBatch("Unknown receipt", status: .unknown, attemptCount: 1)
            let oldConfirmation = ConfirmedUnknownRetry(confirmed: retry)
            try store.saveBatch(retry)
            try await queue.retry(oldConfirmation)
            _ = try #require(await calls.next())
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(try store.batch(id: retry.id)?.records[0].status == .unknown)
            #expect(try store.batch(id: retry.id)?.records[0].attempts.map(\.effect) == [.unknown, .notSubmitted])
            await #expect(throws: QueueError.staleRetryConfirmation) { try await queue.retry(oldConfirmation) }
            await #expect(throws: RetryError.unknownEffectRequiresConfirmation) { try await queue.retry(batchID: retry.id) }
            let latest = try #require(try store.batch(id: retry.id))
            try await queue.retry(.init(confirmed: latest))
            await queue.waitUntilIdle()
            #expect(try store.batch(id: retry.id)?.records[0].attempts.map(\.effect) == [.unknown, .notSubmitted, .completed])
        }
    }

    @Test func ordinaryFailureContinuesAndRetrySkipsOnlyVerifiedCompletedRecords() async throws {
        try await withQueue(firstOutcome: .failed(.unsuccessful, httpStatus: 200)) { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Partial batch", records: 2)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            let partial = try #require(try store.batch(id: first.id))
            #expect(partial.status == .partial)
            #expect(partial.records.map(\.status) == [.failed, .completed])
            var damaged = partial.records[1]
            damaged.dnaSHA256 = .hash("damaged")
            try store.saveRecord(damaged)
            await #expect(throws: RetryError.self) { try await queue.retry(batchID: first.id) }
            #expect(await mock.count == 2)
            try store.saveRecord(partial.records[1])
            try await queue.retry(batchID: first.id)
            await queue.waitUntilIdle()
            let completed = try #require(try store.batch(id: first.id))
            #expect(completed.status == .completed)
            #expect(completed.records[0].attempts.map(\.effect) == [.completed, .completed])
            #expect(completed.records[1] == partial.records[1])
            #expect(await mock.count == 3)
        }
    }

    @Test func tenthAttemptCanDispatchButEleventhCannot() async throws {
        try await withQueue(firstOutcome: .failed(.unsuccessful, httpStatus: 200)) { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let retry = try historicalBatch("Attempt cap", status: .failed, attemptCount: 9)
            try store.saveBatch(retry)
            try await queue.retry(batchID: retry.id)
            let call = try #require(await calls.next())
            #expect(call.record?.attempts.last?.number == 10)
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            await #expect(throws: RetryError.attemptLimit(position: 1, limit: 10)) { try await queue.retry(batchID: retry.id) }
            #expect(await mock.count == 1)
        }
    }

    @Test func immediateExitWaitsForCancellationReceiptAndPreservesUnsentRecords() async throws {
        try await withQueue { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Cancel in flight", records: 2)
            let second = try prepared("Do not start", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            try await queue.submit(.init(confirmed: second))
            try await queue.cancelInFlightForExit()
            let interrupted = try #require(try store.batch(id: first.id))
            #expect(interrupted.status == .unknown)
            #expect(interrupted.records.map(\.status) == [.unknown, .pending])
            #expect(interrupted.records[0].attempts.first?.status == .unknown)
            #expect(interrupted.records[0].attempts.first?.finishedAt != nil)
            #expect(interrupted.records[1].attempts.isEmpty)
            #expect(try store.batch(id: second.id)?.status == .stopped)
            #expect(await mock.count == 1)
        }
    }

    @Test func dispatchWriteFailurePreventsAnySubmission() async throws {
        try await withQueue { queue, store, url, mock, _ in
            let sql = try DatabaseQueue(path: url.path)
            try await sql.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_dispatch BEFORE INSERT ON attempts
                    WHEN NEW.status = 'dispatching' BEGIN SELECT RAISE(ABORT, 'test dispatch failure'); END;
                    """)
            }
            let batch = try prepared("Dispatch write fails", records: 1)
            try await queue.submit(.init(confirmed: batch))
            await queue.waitUntilIdle()
            #expect(await queue.hasStorageFailure)
            #expect(await mock.count == 0)
            #expect(try store.batch(id: batch.id)?.records[0].status == .pending)
            #expect(try store.batch(id: batch.id)?.records[0].attempts.isEmpty == true)
            let reopened = try ProteinStore(url: url)
            #expect(try reopened.batch(id: batch.id)?.status == .stopped)
        }
    }

    @Test func receiptWriteFailureStopsEverythingAndReopeningDoesNotDispatch() async throws {
        try await withQueue { queue, store, url, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Receipt write fails", records: 2)
            let second = try prepared("Never dispatched", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            try await queue.submit(.init(confirmed: second))
            let sql = try DatabaseQueue(path: url.path)
            try await sql.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_receipt BEFORE UPDATE OF status ON attempts
                    WHEN NEW.status = 'completed' BEGIN SELECT RAISE(ABORT, 'test write failure'); END;
                    """)
            }
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(await queue.hasStorageFailure)
            #expect(await mock.count == 1)
            #expect(try store.batch(id: first.id)?.records[0].status == .running)
            await #expect(throws: QueueError.storageFailure) { try await queue.retry(batchID: second.id) }
            let reopened = try ProteinStore(url: url)
            let restarted = QueueCoordinator(store: reopened, service: mock, settings: try testSettings())
            await restarted.waitUntilIdle()
            #expect(await mock.count == 1)
            #expect(try reopened.batch(id: first.id)?.records.map(\.status) == [.unknown, .pending])
            #expect(try reopened.batch(id: first.id)?.records[0].attempts.map(\.status) == [.unknown])
            #expect(try reopened.batch(id: second.id)?.status == .stopped)
        }
    }

    @Test func auditBudgetStopsBeforeAnotherDispatchAndKeepsAllAttempts() async throws {
        try await withQueue { queue, store, _, mock, _ in
            var batch = try prepared("Oversized audit", records: 2)
            batch.status = .stopped
            batch.authorizedAt = .now
            let fullReply = Data(repeating: 0, count: ProteinStore.maximumResponseBytes)
            batch.records[0].status = .failed
            batch.records[0].attempts = (1...7).map { number in
                RequestAttempt(number: number, startedAt: .now, payloadSHA256: .hash("fixture"),
                               status: .failed, effect: .completed, response: fullReply)
            }
            try store.saveBatch(batch)
            try await queue.retry(batchID: batch.id)
            await queue.waitUntilIdle()
            let stopped = try #require(try store.batch(id: batch.id))
            #expect(stopped.status == .stopped)
            #expect(stopped.message == "audit_budget_reached")
            #expect(stopped.records[0].attempts == batch.records[0].attempts)
            #expect(stopped.records[1].attempts.isEmpty)
            #expect(await mock.count == 0)
        }
    }

    @Test func waitingExitFreezesAllPendingWork() async throws {
        try await withQueue { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            let first = try prepared("Finish this request", records: 2)
            let second = try prepared("Do not start", records: 1)
            try await queue.submit(.init(confirmed: first))
            _ = try #require(await calls.next())
            try await queue.submit(.init(confirmed: second))
            try await queue.freezeForExit()
            #expect(try store.batch(id: second.id)?.status == .stopped)
            await #expect(throws: QueueError.closed) { try await queue.retry(batchID: second.id) }
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(await mock.count == 1)
            #expect(try store.batch(id: first.id)?.status == .stopped)
            #expect(try store.batch(id: first.id)?.records.map(\.status) == [.completed, .pending])
        }
    }

    @Test func queueCapacityCountsTheInFlightBatchAndAllowsReplacingAStoppedBatch() async throws {
        try await withQueue { queue, store, _, mock, events in
            var calls = events.makeAsyncIterator()
            try await queue.submit(.init(confirmed: prepared("In flight", records: 1)))
            _ = try #require(await calls.next())
            let batches = try (1...9).map { try prepared("Waiting \($0)", records: 1) }
            for batch in batches { try await queue.submit(.init(confirmed: batch)) }
            let overflow = try prepared("Overflow", records: 1)
            await #expect(throws: QueueError.capacityReached) { try await queue.submit(.init(confirmed: overflow)) }
            #expect(try store.batch(id: overflow.id) == nil)
            try await queue.stop(batchID: batches[0].id)
            try await queue.submit(.init(confirmed: overflow))
            #expect(try store.batch(id: batches[0].id)?.status == .stopped)
            #expect(try store.batch(id: overflow.id)?.status == .queued)
            try await queue.freezeForExit()
            await mock.releaseFirst()
            await queue.waitUntilIdle()
            #expect(await mock.count == 1)
        }
    }

    @Test func settingsAreValidatedAtTheExecutorBoundary() throws {
        for timeout in [0.5, 121, .infinity, .nan] {
            #expect(throws: QueueError.invalidSettings) { try QueueSettings(timeout: timeout) }
        }
        for interval in [0, 99, 10_001] {
            #expect(throws: QueueError.invalidSettings) { try QueueSettings(intervalMilliseconds: interval) }
        }
        #expect(try QueueSettings(timeout: 1, intervalMilliseconds: 100).timeout == 1)
        #expect(try QueueSettings(timeout: 120, intervalMilliseconds: 10_000).intervalMilliseconds == 10_000)
    }
}

private func testSettings() throws -> QueueSettings { try QueueSettings(timeout: 2, intervalMilliseconds: 100) }

private func prepared(_ name: String, records: Int, time: Double = 0) throws -> Batch {
    try BatchPreparation.prepare(name: name, input: .records((1...records).map { .init(name: "Record \($0)", sequence: "M") }),
                                 now: Date(timeIntervalSinceReferenceDate: time))
}

private func historicalBatch(_ name: String, status: RecordStatus, attemptCount: Int) throws -> Batch {
    var batch = try prepared(name, records: 1)
    batch.status = status == .unknown ? .unknown : .failed
    batch.authorizedAt = .now
    batch.records[0].status = status
    batch.records[0].attempts = (1...attemptCount).map { number in
        RequestAttempt(number: number, startedAt: .now, payloadSHA256: .hash("fixture"),
                       status: status == .unknown ? .unknown : .failed,
                       effect: status == .unknown ? .unknown : .completed)
    }
    return batch
}

private func withQueue(
    firstOutcome: ServiceOutcome? = nil,
    _ body: (QueueCoordinator, ProteinStore, URL, MockSubmission, AsyncStream<DispatchObservation>) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("queue.sqlite")
    let store = try ProteinStore(url: url)
    let (events, observer) = AsyncStream<DispatchObservation>.makeStream()
    let mock = MockSubmission(store: store, observer: observer, firstOutcome: firstOutcome)
    let queue = QueueCoordinator(store: store, service: mock, settings: try testSettings())
    do {
        try await body(queue, store, url, mock, events)
    } catch {
        try? await queue.cancelInFlightForExit()
        throw error
    }
}

private struct DispatchObservation: Sendable {
    let batchID: UUID
    let position: Int
    let batchStatus: BatchStatus?
    let authorizedAt: Date?
    let record: SequenceRecord?
    let priorState: SequenceRecord?
    let digest: SHA256Digest
    let instant: ContinuousClock.Instant
}

private actor MockSubmission: ProteinSubmissionService {
    static let goodResponse = Data(#"{"success":1,"seq":"ATG"}"#.utf8)
    private let store: ProteinStore
    private let observer: AsyncStream<DispatchObservation>.Continuation
    private let firstOutcome: ServiceOutcome?
    private var firstRelease: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    init(store: ProteinStore, observer: AsyncStream<DispatchObservation>.Continuation, firstOutcome: ServiceOutcome?) {
        self.store = store
        self.observer = observer
        self.firstOutcome = firstOutcome
    }

    func submit(_ request: ProteinServiceRequest) async -> ProteinServiceReceipt {
        count += 1
        let first = count == 1
        let batch = try? store.batch(id: request.record.batchID)
        let observation = DispatchObservation(
            batchID: request.record.batchID, position: request.record.position, batchStatus: batch?.status,
            authorizedAt: batch?.authorizedAt, record: batch?.records.first { $0.id == request.record.id },
            priorState: batch?.records.first { $0.position == request.record.position - 1 },
            digest: request.payloadSHA256, instant: .now
        )
        if first {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    firstRelease = continuation
                    observer.yield(observation)
                }
            } onCancel: {
                Task { await self.releaseFirst() }
            }
            if Task.isCancelled {
                return ProteinServiceReceipt(outcome: .unknown(.transport(.cancelled), httpStatus: nil))
            }
            if let firstOutcome { return ProteinServiceReceipt(outcome: firstOutcome) }
        } else {
            observer.yield(observation)
        }
        var body = BoundedResponseBody()
        body.append(Self.goodResponse)
        let outcome = ResponseClassifier.classify(httpStatus: 200, body: body, against: request.record.sequence)
        return ProteinServiceReceipt(outcome: outcome, response: Self.goodResponse)
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}
