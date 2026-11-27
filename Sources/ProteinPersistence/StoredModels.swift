import Foundation
import GRDB
import ProteinDomain

protocol StoredRow: Codable, FetchableRecord, PersistableRecord {}

extension StoredRow {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
}

struct StoredBatch: StoredRow {
    static let databaseTableName = "batches"

    let id: String
    let requestId: String
    let name: String
    let species: String
    let startPolicy: String
    let stopPolicy: String
    let avoid: String
    let endpoint: String
    let fingerprint: String
    let createdAt: Double
    let updatedAt: Double
    let authorizedAt: Double?
    let status: String
    let stopRequested: Bool
    let message: String

    init(_ batch: Batch) {
        id = batch.id.uuidString
        requestId = batch.requestID
        name = batch.name
        species = batch.parameters.species.rawValue
        startPolicy = batch.parameters.startPolicy.rawValue
        stopPolicy = batch.parameters.stopPolicy.rawValue
        avoid = batch.parameters.avoid.wireValue
        endpoint = batch.endpoint.absoluteString
        fingerprint = batch.fingerprint.rawValue
        createdAt = storedTime(batch.createdAt)
        updatedAt = storedTime(batch.updatedAt)
        authorizedAt = batch.authorizedAt.map(storedTime)
        status = batch.status.rawValue
        stopRequested = batch.stopRequested
        message = batch.message
    }

    func model(records: [SequenceRecord]) throws -> Batch {
        Batch(
            id: try storedID(id, "batches.id"), requestID: requestId, name: name,
            parameters: try storedParameters(species: species, startPolicy: startPolicy, stopPolicy: stopPolicy,
                                             avoid: avoid, table: "batches"),
            endpoint: try required(URL(string: endpoint), "batches.endpoint"),
            fingerprint: try storedRawValue(fingerprint, "batches.fingerprint"), records: records,
            createdAt: try restoredTime(createdAt, "batches.created_at"),
            updatedAt: try restoredTime(updatedAt, "batches.updated_at"),
            authorizedAt: try authorizedAt.map { try restoredTime($0, "batches.authorized_at") },
            status: try storedRawValue(status, "batches.status"), stopRequested: stopRequested, message: message
        )
    }
}

struct StoredRecord: StoredRow {
    static let databaseTableName = "records"

    let id: String
    let batchId: String
    let position: Int
    let name: String
    let originalSequence: String
    let sequence: String
    let inputSha256: String
    let status: String
    let dna: String?
    let dnaSha256: String?
    let checks: Data?
    let error: String?

    init(_ record: SequenceRecord) throws {
        id = record.id.uuidString
        batchId = record.batchID.uuidString
        position = record.position
        name = record.name
        originalSequence = record.originalSequence.value
        sequence = record.sequence.value
        inputSha256 = record.inputSHA256.rawValue
        status = record.status.rawValue
        dna = record.dna
        dnaSha256 = record.dnaSHA256?.rawValue
        checks = try record.checks.map { try JSONEncoder().encode(StoredChecks($0)) }
        error = record.error
    }

    func model(attempts: [RequestAttempt]) throws -> SequenceRecord {
        SequenceRecord(
            id: try storedID(id, "records.id"), batchID: try storedID(batchId, "records.batch_id"),
            position: position, name: name,
            originalSequence: try storedSequence(originalSequence, "records.original_sequence"),
            sequence: try storedSequence(sequence, "records.sequence"),
            inputSHA256: try storedRawValue(inputSha256, "records.input_sha256"),
            status: try storedRawValue(status, "records.status"), dna: dna,
            dnaSHA256: try dnaSha256.map { try storedRawValue($0, "records.dna_sha256") },
            checks: try checks.map { try required(try? JSONDecoder().decode(StoredChecks.self, from: $0), "records.checks").model },
            error: error, attempts: attempts
        )
    }
}

struct StoredAttempt: StoredRow {
    static let databaseTableName = "attempts"

    let id: String
    let recordId: String
    let number: Int
    let startedAt: Double
    let finishedAt: Double?
    let payloadSha256: String
    let status: String
    let effect: String
    let httpStatus: Int?
    let elapsedMilliseconds: Int?
    let response: Data?
    let error: String?

    init(_ attempt: RequestAttempt, recordID: UUID) throws {
        guard (attempt.response?.count ?? 0) <= ProteinStore.maximumResponseBytes else {
            throw PersistenceError.responseTooLarge(limit: ProteinStore.maximumResponseBytes)
        }
        id = attempt.id.uuidString
        recordId = recordID.uuidString
        number = attempt.number
        startedAt = storedTime(attempt.startedAt)
        finishedAt = attempt.finishedAt.map(storedTime)
        payloadSha256 = attempt.payloadSHA256.rawValue
        status = attempt.status.rawValue
        effect = attempt.effect.rawValue
        httpStatus = attempt.httpStatus
        elapsedMilliseconds = attempt.elapsedMilliseconds
        response = attempt.response
        error = attempt.error
    }

    func model() throws -> RequestAttempt {
        RequestAttempt(
            id: try storedID(id, "attempts.id"), number: number,
            startedAt: try restoredTime(startedAt, "attempts.started_at"),
            payloadSHA256: try storedRawValue(payloadSha256, "attempts.payload_sha256"),
            finishedAt: try finishedAt.map { try restoredTime($0, "attempts.finished_at") },
            status: try storedRawValue(status, "attempts.status"), effect: try storedRawValue(effect, "attempts.effect"),
            httpStatus: httpStatus, elapsedMilliseconds: elapsedMilliseconds, response: response, error: error
        )
    }
}

struct StoredPreset: StoredRow {
    static let databaseTableName = "presets"

    let id: String
    let name: String
    let species: String
    let startPolicy: String
    let stopPolicy: String
    let avoid: String
    let createdAt: Double

    init(_ preset: ParameterPreset) {
        id = preset.id.uuidString
        name = preset.name
        species = preset.parameters.species.rawValue
        startPolicy = preset.parameters.startPolicy.rawValue
        stopPolicy = preset.parameters.stopPolicy.rawValue
        avoid = preset.parameters.avoid.wireValue
        createdAt = storedTime(preset.createdAt)
    }

    func model() throws -> ParameterPreset {
        ParameterPreset(
            id: try storedID(id, "presets.id"), name: name,
            parameters: try storedParameters(species: species, startPolicy: startPolicy, stopPolicy: stopPolicy,
                                             avoid: avoid, table: "presets"),
            createdAt: try restoredTime(createdAt, "presets.created_at")
        )
    }
}

private struct StoredChecks: Codable {
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

    var model: DNAChecks {
        DNAChecks(basePairCount: basePairCount, aminoAcidCount: aminoAcidCount, gcPercent: gcPercent,
                  hasTerminalStop: hasTerminalStop, checkedMotifCount: checkedMotifCount)
    }
}

func storedTime(_ date: Date) -> Double { date.timeIntervalSinceReferenceDate }

func restoredTime(_ time: Double, _ field: String) throws -> Date {
    guard time.isFinite else { throw PersistenceError.invalidStoredValue(field) }
    return Date(timeIntervalSinceReferenceDate: time)
}

func storedID(_ text: String, _ field: String) throws -> UUID {
    try required(UUID(uuidString: text), field)
}

func storedRawValue<T: RawRepresentable>(_ text: String, _ field: String) throws -> T where T.RawValue == String {
    try required(T(rawValue: text), field)
}

private func storedParameters(species: String, startPolicy: String, stopPolicy: String, avoid: String,
                              table: String) throws -> OptimizationParameters {
    OptimizationParameters(
        species: try storedRawValue(species, "\(table).species"),
        startPolicy: try storedRawValue(startPolicy, "\(table).start_policy"),
        stopPolicy: try storedRawValue(stopPolicy, "\(table).stop_policy"),
        avoid: try required(try? AvoidMotifs(canonicalWireValue: avoid), "\(table).avoid")
    )
}

private func storedSequence(_ text: String, _ field: String) throws -> ProteinSequence {
    guard let sequence = try? ProteinSequence(text), sequence.value == text else {
        throw PersistenceError.invalidStoredValue(field)
    }
    return sequence
}

private func required<T>(_ value: T?, _ field: String) throws -> T {
    guard let value else { throw PersistenceError.invalidStoredValue(field) }
    return value
}
