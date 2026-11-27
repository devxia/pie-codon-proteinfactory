import Foundation
import ProteinDomain

public enum ProteinImportRecordIssue: Equatable, Sendable {
    case missingCell(SpreadsheetColumnRole)
    case input(RecordInputError)
}

public struct ProteinImportRecordValidation: Equatable, Sendable {
    public let position: Int
    public let record: ProteinImportRecord
    public let name: String?
    public let originalSequence: ProteinSequence?
    public let issues: [ProteinImportRecordIssue]
}

public struct ProteinImportValidation: Equatable, Sendable {
    public let records: [ProteinImportRecordValidation]
    public let parameters: OptimizationParameters
    public let batchIssues: [BatchInputError]

    public var isValid: Bool { batchIssues.isEmpty && records.allSatisfy { $0.issues.isEmpty } }
}

public enum ProteinImportPreparationError: Error, Equatable, Sendable {
    case validationFailed
}

public struct ProteinImportPreviewRecord: Equatable, Sendable {
    public let position: Int
    public let source: ProteinImportSource
    public let name: String
    public let rawSequence: String
    public let originalSequence: ProteinSequence
    public let submittedSequence: ProteinSequence
}

public struct ProteinImportPreview: Sendable {
    public let batch: Batch
    public let records: [ProteinImportPreviewRecord]

    public var recordCount: Int { batch.records.count }
    public var originalSequenceLength: Int { batch.originalSequenceLength }
    public var submittedSequenceLength: Int { batch.submittedSequenceLength }
    public var parameters: OptimizationParameters { batch.parameters }
    public var finalMotifs: [String] { parameters.avoid.motifs }
    public var endpoint: URL { batch.endpoint }
    public var fingerprint: SHA256Digest { batch.fingerprint }
}

extension ProteinImport {
    public static func validate(
        _ input: [ProteinImportRecord], parameters: OptimizationParameters = .init()
    ) throws -> ProteinImportValidation {
        var batchIssues: [BatchInputError] = []
        let countRange = 1...ProteinDomainLimits.maximumRecords
        if !countRange.contains(input.count) { batchIssues.append(.recordCount(limit: countRange)) }

        var total = 0
        let records = try input.enumerated().map { index, record in
            let result = try validateRecord(record, position: index + 1, stopPolicy: parameters.stopPolicy)
            total += result.originalSequence?.value.utf8.count ?? 0
            return result
        }
        let lengthLimit = ProteinDomainLimits.maximumBatchLength
        if total > lengthLimit { batchIssues.append(.totalLengthExceedsLimit(limit: lengthLimit)) }
        return ProteinImportValidation(records: records, parameters: parameters, batchIssues: batchIssues)
    }

    public static func prepare(
        name: String, validation: ProteinImportValidation, requestID: String = UUID().uuidString, now: Date = Date()
    ) throws -> ProteinImportPreview {
        guard validation.isValid else { throw ProteinImportPreparationError.validationFailed }
        let inputs = try validation.records.map { result -> (source: ProteinImportSource, input: SequenceRecordInput) in
            let record = result.record
            guard let rawName = record.rawName, let rawSequence = record.rawSequence else {
                throw ProteinImportPreparationError.validationFailed
            }
            return (record.source, SequenceRecordInput(name: rawName, sequence: rawSequence, sourceRow: record.source.sourceRow))
        }
        let batch = try BatchPreparation.prepare(
            name: name, input: .records(inputs.map { $0.input }),
            parameters: validation.parameters, requestID: requestID, now: now
        )
        let records = zip(batch.records, inputs).map { record, imported in
            ProteinImportPreviewRecord(
                position: record.position, source: imported.source, name: record.name,
                rawSequence: imported.input.sequence, originalSequence: record.originalSequence,
                submittedSequence: record.sequence
            )
        }
        return ProteinImportPreview(batch: batch, records: records)
    }

    private static func validateRecord(
        _ record: ProteinImportRecord, position: Int, stopPolicy: StopPolicy
    ) throws -> ProteinImportRecordValidation {
        var issues: [ProteinImportRecordIssue] = []
        let name = record.rawName.flatMap(BatchPreparation.validatedRecordName)
        if record.rawName == nil {
            issues.append(.missingCell(.name))
        } else if name == nil {
            issues.append(.input(.invalidName))
        }

        var original: ProteinSequence?
        if let raw = record.rawSequence {
            do {
                let sequence = try ProteinSequence(raw)
                original = sequence
                _ = try sequence.applying(stopPolicy)
            } catch let error as ProteinSequenceError {
                issues.append(.input(.sequence(error)))
            }
        } else {
            issues.append(.missingCell(.sequence))
        }
        return ProteinImportRecordValidation(
            position: position, record: record, name: name, originalSequence: original, issues: issues
        )
    }
}
