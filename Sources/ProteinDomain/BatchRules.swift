import Foundation

public struct BatchSummary: Equatable, Sendable {
    public let pending: Int
    public let running: Int
    public let completed: Int
    public let failed: Int
    public let unknown: Int

    public var total: Int { pending + running + done }
    public var done: Int { completed + failed + unknown }

    public init(statuses: some Sequence<RecordStatus>) {
        var counts: [RecordStatus: Int] = [:]
        for status in statuses { counts[status, default: 0] += 1 }
        pending = counts[.pending, default: 0]
        running = counts[.running, default: 0]
        completed = counts[.completed, default: 0]
        failed = counts[.failed, default: 0]
        unknown = counts[.unknown, default: 0]
    }

    public var statusAfterExecution: BatchStatus? {
        if unknown > 0 { return .unknown }
        if running > 0 { return nil }
        if completed > 0, completed == total { return .completed }
        if pending > 0 { return .stopped }
        if completed > 0 { return .partial }
        return .failed
    }
}

public enum RetryIntent: Equatable, Sendable {
    case ordinary
    case confirmedUnknownEffect
}

public enum RetryError: Error, Equatable, Sendable {
    case invalidBatchState(BatchStatus)
    case recordStillRunning(position: Int)
    case unknownEffectRequiresConfirmation
    case noPendingRecords
    case attemptLimit(position: Int, limit: Int)
    case invalidCompletedRecord(position: Int, reason: SavedDNAError)
    case failedCompletedRecordVerification(position: Int, reason: DNAValidationError)
}

public struct RetryPlan: Equatable, Sendable {
    public let recordIDsToRetry: [UUID]
    public let completedRecordIDsToSkip: [UUID]
}

public enum RetryPolicy {
    public static func plan(for batch: Batch, intent: RetryIntent) throws -> RetryPlan {
        try PreviewIntegrity.verify(batch)
        switch batch.status {
        case .prepared, .queued, .running: throw RetryError.invalidBatchState(batch.status)
        case .completed, .partial, .failed, .stopped, .unknown: break
        }
        if let running = batch.records.first(where: { $0.status == .running }) {
            throw RetryError.recordStillRunning(position: running.position)
        }
        guard intent == .confirmedUnknownEffect || !batch.records.contains(where: { $0.status == .unknown }) else {
            throw RetryError.unknownEffectRequiresConfirmation
        }
        guard batch.records.contains(where: { $0.status != .completed }) else {
            throw RetryError.noPendingRecords
        }
        var retry: [UUID] = []
        var skip: [UUID] = []
        for record in batch.records {
            if record.status == .completed {
                do {
                    _ = try DNAValidation.reverifyCompleted(
                        record, avoiding: batch.parameters.avoid, startPolicy: batch.parameters.startPolicy
                    )
                } catch let error as SavedDNAError {
                    throw RetryError.invalidCompletedRecord(position: record.position, reason: error)
                } catch let error as DNAValidationError {
                    throw RetryError.failedCompletedRecordVerification(position: record.position, reason: error)
                }
                skip.append(record.id)
            } else {
                guard record.attempts.count < ProteinDomainLimits.maximumAttempts,
                      (record.attempts.last?.number ?? 0) < ProteinDomainLimits.maximumAttempts else {
                    throw RetryError.attemptLimit(position: record.position, limit: ProteinDomainLimits.maximumAttempts)
                }
                retry.append(record.id)
            }
        }
        return RetryPlan(recordIDsToRetry: retry, completedRecordIDsToSkip: skip)
    }
}
