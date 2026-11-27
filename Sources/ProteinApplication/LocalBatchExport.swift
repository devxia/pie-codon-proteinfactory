import Foundation
import ProteinDomain
import ZIPFoundation

public enum LocalBatchExport {
    public enum Format: Sendable {
        case inputFASTA
        case auditZIP
        case synthesisCSV
    }

    public enum ExportError: Error, Equatable, Sendable {
        case exceedsSizeLimit
        case invalidArchive
        case noVerifiedResults
    }

    private static let maximumBytes = 10 * 1_024 * 1_024

    public static func data(for batch: Batch, format: Format) throws -> Data {
        switch format {
        case .inputFASTA:
            let input = inputFASTA(batch.records)
            guard input.count <= maximumBytes else { throw ExportError.exceedsSizeLimit }
            return input
        case .synthesisCSV:
            return try synthesisCSV(batch)
        case .auditZIP:
            let input = inputFASTA(batch.records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let audit = try encoder.encode(AuditBatch(batch))
            let readme = Data("""
                Codon ProteinFactory local batch audit

                job.json contains batch, record, and attempt metadata. Response bodies and DNA are omitted.
                input.fasta contains the original normalized protein sequences, in batch order.
                Stored verification statistics describe sequence checks. Experimental expression was not assessed.

                """.utf8)
            return try zip([("job.json", audit), ("input.fasta", input), ("README.txt", readme)])
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        guard data.count <= maximumBytes else { throw ExportError.exceedsSizeLimit }
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }

    private static func inputFASTA(_ records: [SequenceRecord]) -> Data {
        var text = ""
        for record in records {
            let name = record.name.split(whereSeparator: { $0.isWhitespace || $0.isControlOrFormat })
                .joined(separator: " ").replacingOccurrences(of: ">", with: "_")
            text += ">\(name.isEmpty ? "record-\(record.position)" : name)\n"
            let sequence = Array(record.originalSequence.value.utf8)
            for start in stride(from: 0, to: sequence.count, by: 80) {
                text += String(decoding: sequence[start..<min(start + 80, sequence.count)], as: UTF8.self) + "\n"
            }
        }
        return Data(text.utf8)
    }

    private static func synthesisCSV(_ batch: Batch) throws -> Data {
        var text = "Number,Name,Protein Sequence,Codon-Optimized DNA Sequence\r\n"
        var count = 0
        for record in batch.records where record.status == .completed {
            try Task.checkCancellation()
            guard let verified = try? DNAValidation.reverifyCompleted(
                record, avoiding: batch.parameters.avoid, startPolicy: batch.parameters.startPolicy
            ) else { continue }
            count += 1
            text += "\(count),\(csvField(record.name)),\(record.originalSequence.value),\(verified.dna)\r\n"
        }
        guard count > 0 else { throw ExportError.noVerifiedResults }
        let data = Data(text.utf8)
        guard data.count <= maximumBytes else { throw ExportError.exceedsSizeLimit }
        return data
    }

    private static func csvField(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func zip(_ members: [(String, Data)]) throws -> Data {
        guard members.reduce(0, { $0 + $1.1.count }) <= maximumBytes else { throw ExportError.exceedsSizeLimit }
        let archive = try Archive(data: Data(), accessMode: .create)
        for (path, contents) in members {
            try Task.checkCancellation()
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(contents.count), compressionMethod: .deflate) {
                position, size in
                let start = Int(position)
                return contents.subdata(in: start..<(start + size))
            }
        }
        guard let bytes = archive.data, bytes.count <= maximumBytes else { throw ExportError.exceedsSizeLimit }
        let verification = try Archive(data: bytes, accessMode: .read)
        guard Array(verification.map(\.path)) == members.map(\.0) else { throw ExportError.invalidArchive }
        for (path, contents) in members {
            guard let entry = verification[path] else { throw ExportError.invalidArchive }
            var restored = Data()
            let crc = try verification.extract(entry) { restored.append($0) }
            guard crc == entry.checksum, restored == contents else { throw ExportError.invalidArchive }
        }
        return bytes
    }
}

private extension Character {
    var isControlOrFormat: Bool {
        unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }
}

private struct AuditBatch: Encodable {
    let schemaVersion = 1
    let id: UUID
    let requestID: String
    let name: String
    let status: String
    let createdAt: Date
    let updatedAt: Date
    let authorizedAt: Date?
    let recipient: URL
    let fingerprint: String
    let stopRequested: Bool
    let host: String
    let startCodonPolicy: String
    let terminalStopPolicy: String
    let motifs: [String]
    let records: [AuditRecord]

    init(_ batch: Batch) {
        id = batch.id
        requestID = batch.requestID
        name = batch.name
        status = batch.status.rawValue
        createdAt = batch.createdAt
        updatedAt = batch.updatedAt
        authorizedAt = batch.authorizedAt
        recipient = batch.endpoint
        fingerprint = batch.fingerprint.rawValue
        stopRequested = batch.stopRequested
        host = batch.parameters.species.rawValue
        startCodonPolicy = batch.parameters.startPolicy.rawValue
        terminalStopPolicy = batch.parameters.stopPolicy.rawValue
        motifs = batch.parameters.avoid.motifs
        records = batch.records.map(AuditRecord.init)
    }
}

private struct AuditRecord: Encodable {
    let id: UUID
    let position: Int
    let name: String
    let status: String
    let originalProtein: String
    let preparedProtein: String
    let inputSHA256: String
    let dnaSHA256: String?
    let checks: AuditChecks?
    let attempts: [AuditAttempt]

    init(_ record: SequenceRecord) {
        id = record.id
        position = record.position
        name = record.name
        status = record.status.rawValue
        originalProtein = record.originalSequence.value
        preparedProtein = record.sequence.value
        inputSHA256 = record.inputSHA256.rawValue
        dnaSHA256 = record.dnaSHA256?.rawValue
        checks = record.checks.map(AuditChecks.init)
        attempts = record.attempts.map(AuditAttempt.init)
    }
}

private struct AuditChecks: Encodable {
    let basePairCount: Int
    let aminoAcidCount: Int
    let gcPercent: Double
    let hasTerminalStop: Bool
    let checkedMotifCount: Int

    init(_ checks: DNAChecks) {
        basePairCount = checks.basePairCount
        aminoAcidCount = checks.aminoAcidCount
        gcPercent = checks.gcPercent
        hasTerminalStop = checks.hasTerminalStop
        checkedMotifCount = checks.checkedMotifCount
    }
}

private struct AuditAttempt: Encodable {
    let id: UUID
    let number: Int
    let status: String
    let effect: String
    let startedAt: Date
    let finishedAt: Date?
    let elapsedMilliseconds: Int?
    let httpStatus: Int?
    let payloadSHA256: String

    init(_ attempt: RequestAttempt) {
        id = attempt.id
        number = attempt.number
        status = attempt.status.rawValue
        effect = attempt.effect.rawValue
        startedAt = attempt.startedAt
        finishedAt = attempt.finishedAt
        elapsedMilliseconds = attempt.elapsedMilliseconds
        httpStatus = attempt.httpStatus
        payloadSHA256 = attempt.payloadSHA256.rawValue
    }
}
