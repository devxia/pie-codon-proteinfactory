import Foundation

public struct SequenceRecordInput: Equatable, Sendable {
    public let name: String
    public let sequence: String
    public let sourceRow: Int?

    public init(name: String, sequence: String, sourceRow: Int? = nil) {
        self.name = name
        self.sequence = sequence
        self.sourceRow = sourceRow
    }
}

public enum BatchInput: Equatable, Sendable {
    case text(String, singleRecordName: String? = nil)
    case records([SequenceRecordInput])
}

public struct RecordLocation: Equatable, Sendable {
    public let position: Int
    public let sourceRow: Int?

    public init(position: Int, sourceRow: Int? = nil) {
        self.position = position
        self.sourceRow = sourceRow
    }
}

public enum RecordInputError: Error, Equatable, Sendable {
    case invalidName
    case sequence(ProteinSequenceError)
}

public enum BatchInputError: Error, Equatable, Sendable {
    case invalidBatchName
    case invalidRequestID
    case textTooLarge(limit: Int)
    case recordCount(limit: ClosedRange<Int>)
    case totalLengthExceedsLimit(limit: Int)
    case record(location: RecordLocation, reason: RecordInputError)
}

public enum BatchPreparation {
    public static func prepare(
        name rawName: String,
        input: BatchInput,
        parameters: OptimizationParameters = .init(),
        requestID rawRequestID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> Batch {
        guard let name = validatedName(rawName, maximum: 200) else { throw BatchInputError.invalidBatchName }
        guard let requestID = validatedName(rawRequestID, maximum: 200) else { throw BatchInputError.invalidRequestID }
        let inputs = try records(from: input)
        let recordRange = 1...ProteinDomainLimits.maximumRecords
        guard recordRange.contains(inputs.count) else { throw BatchInputError.recordCount(limit: recordRange) }

        let batchID = UUID()
        var total = 0
        var records: [SequenceRecord] = []
        records.reserveCapacity(inputs.count)
        for (index, input) in inputs.enumerated() {
            let location = RecordLocation(position: index + 1, sourceRow: input.sourceRow)
            guard let name = validatedRecordName(input.name) else {
                throw BatchInputError.record(location: location, reason: .invalidName)
            }
            let original: ProteinSequence
            let submitted: ProteinSequence
            do {
                original = try ProteinSequence(input.sequence)
                submitted = try original.applying(parameters.stopPolicy)
            } catch let error as ProteinSequenceError {
                throw BatchInputError.record(location: location, reason: .sequence(error))
            }
            total += original.value.utf8.count
            guard total <= ProteinDomainLimits.maximumBatchLength else {
                throw BatchInputError.totalLengthExceedsLimit(limit: ProteinDomainLimits.maximumBatchLength)
            }
            records.append(SequenceRecord(
                batchID: batchID, position: location.position, name: name,
                originalSequence: original, sequence: submitted, inputSHA256: .hash(submitted.value)
            ))
        }
        let endpoint = Batch.serviceEndpoint
        return Batch(
            id: batchID, requestID: requestID, name: name, parameters: parameters, endpoint: endpoint,
            fingerprint: PreviewIntegrity.fingerprint(name: name, records: records, parameters: parameters, endpoint: endpoint),
            records: records, createdAt: now, updatedAt: now
        )
    }

    public static func validatedRecordName(_ raw: String) -> String? {
        validatedName(raw, maximum: 300)
    }

    private static func records(from input: BatchInput) throws -> [SequenceRecordInput] {
        switch input {
        case .records(let records):
            return records
        case .text(let text, let name):
            guard text.utf8.count <= ProteinDomainLimits.maximumTextBytes else {
                throw BatchInputError.textTooLarge(limit: ProteinDomainLimits.maximumTextBytes)
            }
            guard let start = text.unicodeScalars.firstIndex(where: { !isSequenceWhitespace($0) }),
                  text.unicodeScalars[start] == ">" else {
                let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return [.init(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Protein 1", sequence: text)]
            }
            let firstRow = text[..<start].reduce(1) { $1.isNewline ? $0 + 1 : $0 }
            return try fastaRecords(text[start...], startingAt: firstRow)
        }
    }

    private static func fastaRecords(_ text: Substring, startingAt firstRow: Int) throws -> [SequenceRecordInput] {
        var records: [SequenceRecordInput] = []
        var name: String?
        var sequence = ""
        var headerRow = firstRow
        var row = firstRow
        var remaining = text
        while !remaining.isEmpty {
            let end = remaining.firstIndex(where: \.isNewline) ?? remaining.endIndex
            let line = remaining[..<end]
            if line.utf8.first == 62 {
                if let name { records.append(.init(name: name, sequence: sequence, sourceRow: headerRow)) }
                guard records.count < ProteinDomainLimits.maximumRecords else {
                    throw BatchInputError.recordCount(limit: 1...ProteinDomainLimits.maximumRecords)
                }
                name = String(line.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                sequence = ""
                headerRow = row
            } else if !line.isEmpty {
                sequence += line
            }
            guard end < remaining.endIndex else { break }
            remaining = remaining[remaining.index(after: end)...]
            row += 1
        }
        if let name { records.append(.init(name: name, sequence: sequence, sourceRow: headerRow)) }
        return records
    }

    private static func validatedName(_ raw: String, maximum: Int) -> String? {
        guard raw.utf16.count <= maximum,
              !raw.unicodeScalars.contains(where: { $0.value <= 31 || $0.value == 127 }) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
