import Foundation
import GRDB
import ProteinDomain

public enum PersistenceError: Error, Equatable, Sendable, LocalizedError {
    case openingFailed
    case corruptedDatabase
    case incompatibleSchema
    case unsupportedSchemaVersion(Int)
    case migrationFailed
    case recoveryFailed
    case invalidStoredValue(String)
    case invalidRecordLayout
    case invalidAttemptIdentity
    case responseTooLarge(limit: Int)
    case invalidPresetName
    case invalidHistoryPage

    public var errorDescription: String? {
        switch self {
        case .openingFailed: "The local database could not be opened."
        case .corruptedDatabase: "The local database failed its integrity check. The original file has been retained."
        case .incompatibleSchema: "The local database does not have a recognized schema."
        case .unsupportedSchemaVersion(let version): "Local database schema version \(version) is not supported by this app."
        case .migrationFailed: "The local database could not be migrated. The original file has been retained."
        case .recoveryFailed: "Interrupted work could not be recovered. The original file has been retained."
        case .invalidStoredValue(let field): "The local database contains an invalid value in \(field)."
        case .invalidRecordLayout: "The records do not belong to this batch or do not have unique positions and identifiers."
        case .invalidAttemptIdentity: "An attempt identifier cannot be reused or assigned to another record or attempt number."
        case .responseTooLarge(let limit): "The attempt response exceeds the \(limit)-byte storage limit."
        case .invalidPresetName: "A preset name must have between 1 and 80 characters."
        case .invalidHistoryPage: "History pages must have a nonnegative offset and a limit between 1 and 200."
        }
    }
}

public struct ParameterPreset: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let parameters: OptimizationParameters
    public let createdAt: Date
}

public struct BatchHistoryEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let status: BatchStatus
    public let updatedAt: Date
    public let recordCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let unknownCount: Int
}

public final class ProteinStore: Sendable {
    public static let maximumResponseBytes = 1_048_576
    public static var currentSchemaVersion: Int { PersistenceSchema.version }

    private let queue: DatabaseQueue

    /// Opens the local store and performs recovery. Call once at startup before starting an executor.
    public init(url: URL, recoveringAt: Date = .now) throws {
        guard url.isFileURL else { throw PersistenceError.openingFailed }
        let queue = try startup(fallback: .openingFailed) { try DatabaseQueue(path: url.path) }
        let version = try startup(fallback: .incompatibleSchema) {
            try queue.read { db in
                try PersistenceSchema.checkIntegrity(db)
                return try PersistenceSchema.checkVersion(db)
            }
        }
        if version < Self.currentSchemaVersion {
            try startup(fallback: .migrationFailed) {
                try PersistenceSchema.migrator.migrate(queue)
                try queue.read { db in
                    try PersistenceSchema.checkIntegrity(db)
                    guard try PersistenceSchema.checkVersion(db) == Self.currentSchemaVersion else {
                        throw PersistenceError.migrationFailed
                    }
                }
            }
        }
        try startup(fallback: .recoveryFailed) {
            try queue.write { db in try recoverInterruptedWork(db, at: recoveringAt) }
        }
        self.queue = queue
    }

    /// Saves the batch and supplied descendants atomically without deleting omitted audit rows.
    public func saveBatch(_ batch: Batch) throws {
        guard batch.records.allSatisfy({ $0.batchID == batch.id }),
              Set(batch.records.map(\.id)).count == batch.records.count,
              Set(batch.records.map(\.position)).count == batch.records.count else {
            throw PersistenceError.invalidRecordLayout
        }
        try queue.write { db in
            try StoredBatch(batch).save(db)
            for record in batch.records { try persist(record, attempts: record.attempts, in: db) }
        }
    }

    /// Persists a first submission without overwriting an existing batch or reusing a request ID.
    public func insertNewBatch(_ batch: Batch) throws -> Bool {
        try queue.write { db in
            let duplicate = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM batches WHERE id = ? OR request_id = ?)
                """, arguments: [batch.id.uuidString, batch.requestID])
            guard duplicate == false else { return false }
            try StoredBatch(batch).insert(db)
            for record in batch.records { try persist(record, attempts: record.attempts, in: db) }
            return true
        }
    }

    /// Changes scheduling state atomically without rewriting the records or audit trail.
    public func updateBatchMetadata(_ batches: [Batch]) throws {
        try queue.write { db in
            for batch in batches { try StoredBatch(batch).update(db) }
        }
    }

    /// Counts the JSON representation of the batch, including every stored audit field.
    public static func exceedsAuditBudget(_ batch: Batch, limit: Int) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var size = try encoder.encode(StoredBatch(batch)).count
        size += #"{"batch":,"records":[],"attempts":[]}"#.utf8.count
        var recordSeparator = 0
        var attemptSeparator = 0
        for record in batch.records {
            size += try encoder.encode(StoredRecord(record)).count + recordSeparator
            if size > limit { return true }
            recordSeparator = 1
            for attempt in record.attempts {
                size += try encoder.encode(StoredAttempt(attempt, recordID: record.id)).count + attemptSeparator
                if size > limit { return true }
                attemptSeparator = 1
            }
        }
        return size > limit
    }

    public func batch(id: UUID, includingResponses: Bool = true) throws -> Batch? {
        try queue.read { db in
            guard let batch = try StoredBatch.fetchOne(db, key: id.uuidString) else { return nil }
            return try batch.model(records: loadRecords(db, batchID: id, status: nil, includingResponses: includingResponses))
        }
    }

    public func attemptResponse(id: UUID, recordID: UUID) throws -> Data? {
        try queue.read { db in
            let statement = """
                SELECT response FROM attempts WHERE id = ? AND record_id = ? AND length(response) <= ?
                """
            return try Data.fetchOne(db, sql: statement, arguments: [id.uuidString, recordID.uuidString, Self.maximumResponseBytes])
        }
    }

    public func batchHistory(nameContaining search: String = "", status: BatchStatus? = nil,
                             limit: Int = 50, offset: Int = 0) throws -> [BatchHistoryEntry] {
        guard (1...200).contains(limit), offset >= 0 else { throw PersistenceError.invalidHistoryPage }
        return try queue.read { db in
            let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            var conditions: [String] = []
            var arguments = StatementArguments()
            if let status {
                conditions.append("status = ?")
                arguments += [status.rawValue]
            }
            if !search.isEmpty {
                conditions.append("name LIKE ? ESCAPE '\\'")
                arguments += ["%\(search)%"]
            }
            let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            arguments += [limit, offset]
            return try StoredHistoryEntry.fetchAll(db, sql: """
                WITH page AS (
                    SELECT id, name, status, updated_at FROM batches \(filter)
                    ORDER BY updated_at DESC, id LIMIT ? OFFSET ?
                )
                SELECT page.*, count(records.id) AS record_count,
                       count(CASE WHEN records.status = 'completed' THEN 1 END) AS completed_count,
                       count(CASE WHEN records.status = 'failed' THEN 1 END) AS failed_count,
                       count(CASE WHEN records.status = 'unknown' THEN 1 END) AS unknown_count
                FROM page LEFT JOIN records ON page.id = records.batch_id
                GROUP BY page.id ORDER BY page.updated_at DESC, page.id
                """, arguments: arguments).map { try $0.model() }
        }
    }

    @discardableResult
    public func deleteBatch(id: UUID) throws -> Bool {
        try queue.write { db in try StoredBatch.deleteOne(db, key: id.uuidString) }
    }

    @discardableResult
    public func deleteInactiveBatch(id: UUID) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM batches WHERE id = ? AND status NOT IN (?, ?)
                """, arguments: [id.uuidString, BatchStatus.queued.rawValue, BatchStatus.running.rawValue])
            return db.changesCount == 1
        }
    }

    /// Persists a dispatch or receipt with its record state, and optional batch metadata, in one transaction.
    /// An optional batch supplies metadata only; its embedded records are not written by this method.
    public func saveRecord(_ record: SequenceRecord, updatingBatch batch: Batch? = nil) throws {
        try writeRecord(record, attempts: record.attempts, updatingBatch: batch)
    }

    /// Writes one attempt and its new record state without rewriting the record's previous attempts.
    public func saveAttempt(_ attempt: RequestAttempt, updatingRecord record: SequenceRecord, updatingBatch batch: Batch? = nil) throws {
        try writeRecord(record, attempts: [attempt], updatingBatch: batch)
    }

    private func writeRecord(_ record: SequenceRecord, attempts: [RequestAttempt], updatingBatch batch: Batch?) throws {
        guard batch == nil || batch?.id == record.batchID else { throw PersistenceError.invalidRecordLayout }
        try queue.write { db in
            if let batch {
                try StoredBatch(batch).update(db)
            }
            try persist(record, attempts: attempts, in: db)
        }
    }

    public func record(id: UUID) throws -> SequenceRecord? {
        try queue.read { db in
            guard let record = try StoredRecord.fetchOne(db, key: id.uuidString) else { return nil }
            return try record.model(attempts: loadAttempts(db, recordID: id))
        }
    }

    public func records(batchID: UUID, status: RecordStatus? = nil) throws -> [SequenceRecord] {
        try queue.read { db in try loadRecords(db, batchID: batchID, status: status) }
    }

    public func attempts(recordID: UUID) throws -> [RequestAttempt] {
        try queue.read { db in try loadAttempts(db, recordID: recordID) }
    }

    @discardableResult
    public func createPreset(name: String, parameters: OptimizationParameters, createdAt: Date = .now) throws -> ParameterPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { throw PersistenceError.invalidPresetName }
        let preset = ParameterPreset(id: UUID(), name: name, parameters: parameters, createdAt: createdAt)
        try queue.write { db in try StoredPreset(preset).insert(db) }
        return preset
    }

    public func presets() throws -> [ParameterPreset] {
        try queue.read { db in
            try StoredPreset.order(Column("created_at").desc, Column("id")).fetchAll(db).map { try $0.model() }
        }
    }

    @discardableResult
    public func deletePreset(id: UUID) throws -> Bool {
        try queue.write { db in try StoredPreset.deleteOne(db, key: id.uuidString) }
    }
}

private func persist(_ record: SequenceRecord, attempts: [RequestAttempt], in db: Database) throws {
    let stored = try StoredRecord(record)
    guard Set(attempts.map(\.id)).count == attempts.count else { throw PersistenceError.invalidAttemptIdentity }
    if try StoredRecord.exists(db, key: stored.id) {
        guard try StoredRecord.filter(key: stored.id).filter(Column("batch_id") == stored.batchId)
            .filter(Column("position") == stored.position).fetchCount(db) == 1 else {
            throw PersistenceError.invalidRecordLayout
        }
        try stored.update(db)
    } else {
        try stored.insert(db)
    }
    for attempt in attempts {
        let stored = try StoredAttempt(attempt, recordID: record.id)
        if try StoredAttempt.exists(db, key: stored.id) {
            guard try StoredAttempt.filter(key: stored.id).filter(Column("record_id") == stored.recordId)
                .filter(Column("number") == stored.number).fetchCount(db) == 1 else {
                throw PersistenceError.invalidAttemptIdentity
            }
            try stored.update(db)
        } else {
            try stored.insert(db)
        }
    }
}

private func loadRecords(_ db: Database, batchID: UUID, status: RecordStatus?, includingResponses: Bool = true) throws -> [SequenceRecord] {
    var query = StoredRecord.filter(Column("batch_id") == batchID.uuidString)
    if let status { query = query.filter(Column("status") == status.rawValue) }
    let records = try query.order(Column("position")).fetchAll(db)
    guard !records.isEmpty else { return [] }
    let columns = includingResponses ? "attempts.*" : """
        attempts.id, attempts.record_id, attempts.number, attempts.started_at, attempts.finished_at,
        attempts.payload_sha256, attempts.status, attempts.effect, attempts.http_status, attempts.elapsed_milliseconds,
        NULL AS response, attempts.error
        """
    let attempts = try StoredAttempt.fetchAll(db, sql: """
        SELECT \(columns) FROM attempts JOIN records ON records.id = attempts.record_id
        WHERE records.batch_id = ? \(status == nil ? "" : "AND records.status = ?")
        ORDER BY attempts.record_id, attempts.number
        """, arguments: StatementArguments(status.map { [batchID.uuidString, $0.rawValue] } ?? [batchID.uuidString]))
    let grouped = Dictionary(grouping: attempts, by: \.recordId)
    return try records.map { record in
        try record.model(attempts: (grouped[record.id] ?? []).map { try $0.model() })
    }
}

private func loadAttempts(_ db: Database, recordID: UUID) throws -> [RequestAttempt] {
    try StoredAttempt.filter(Column("record_id") == recordID.uuidString).order(Column("number"))
        .fetchAll(db).map { try $0.model() }
}

private func startup<T>(fallback: PersistenceError, _ operation: () throws -> T) throws -> T {
    do {
        return try operation()
    } catch let error as PersistenceError {
        throw error
    } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT {
        throw PersistenceError.corruptedDatabase
    } catch {
        throw fallback
    }
}

private struct StoredHistoryEntry: Decodable, FetchableRecord {
    static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    let id: String
    let name: String
    let status: String
    let updatedAt: Double
    let recordCount: Int
    let completedCount: Int
    let failedCount: Int
    let unknownCount: Int

    func model() throws -> BatchHistoryEntry {
        BatchHistoryEntry(id: try storedID(id, "batches.id"), name: name,
                          status: try storedRawValue(status, "batches.status"),
                          updatedAt: try restoredTime(updatedAt, "batches.updated_at"), recordCount: recordCount,
                          completedCount: completedCount, failedCount: failedCount, unknownCount: unknownCount)
    }
}
