import Foundation
import GRDB
import ProteinDomain
@testable import ProteinPersistence
import Testing

struct PersistenceSchemaTests {
    private func insertLegacyBatch(_ batch: Batch, into database: Database) throws {
        let row = StoredBatch(batch)
        try database.execute(sql: """
            INSERT INTO batches (id, request_id, name, species, stop_policy, avoid, endpoint, fingerprint,
                                 created_at, updated_at, authorized_at, status, stop_requested, message)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [row.id, row.requestId, row.name, row.species, row.stopPolicy, row.avoid,
                             row.endpoint, row.fingerprint, row.createdAt, row.updatedAt, row.authorizedAt,
                             row.status, row.stopRequested, row.message])
        for record in batch.records { try StoredRecord(record).insert(database) }
    }

    private func insertLegacyPreset(_ preset: ParameterPreset, into database: Database) throws {
        let row = StoredPreset(preset)
        try database.execute(sql: """
            INSERT INTO presets (id, name, species, stop_policy, avoid, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [row.id, row.name, row.species, row.stopPolicy, row.avoid, row.createdAt])
    }
    @Test func upgradesVersionOneAndRetainsExistingRows() throws {
        try withTemporaryDatabase { url in
            let existing = try sampleBatch()
            do {
                let sql = try DatabaseQueue(path: url.path)
                try PersistenceSchema.migrator.migrate(sql, upTo: "initial")
                try sql.write { db in
                    try insertLegacyBatch(existing, into: db)
                    try insertLegacyPreset(ParameterPreset(id: UUID(), name: "Legacy", parameters: existing.parameters,
                                    createdAt: Date(timeIntervalSinceReferenceDate: 1)), into: db)
                }
            }
            #expect(try ProteinStore(url: url).batch(id: existing.id) == existing)
            #expect(try ProteinStore(url: url).presets().first?.parameters.startPolicy == StartCodonPolicy.none)
            let sql = try DatabaseQueue(path: url.path)
            try sql.read { db throws in
                #expect(try PersistenceSchema.checkVersion(db) == ProteinStore.currentSchemaVersion)
                #expect(try String.fetchAll(db, sql: "SELECT migration FROM schema_metadata ORDER BY version") ==
                    ["initial", "historyIndexes", "startCodonPolicy"])
                #expect(try String.fetchOne(db, sql: "SELECT applied_at FROM schema_metadata WHERE version = 2")?.isEmpty == false)
                #expect(try String.fetchOne(db, sql: "SELECT name FROM sqlite_schema WHERE type = 'index' AND name = 'batches_updated'") != nil)
            }
        }
    }

    @Test func failedMigrationRollsBackTheWholeVersionAndKeepsExistingData() throws {
        try withTemporaryDatabase { url in
            let existing = try sampleBatch()
            do {
                let sql = try DatabaseQueue(path: url.path)
                try PersistenceSchema.migrator.migrate(sql, upTo: "initial")
                try sql.write { db in
                    try insertLegacyBatch(existing, into: db)
                    try db.execute(sql: "CREATE INDEX batches_status_updated ON batches(status)")
                }
            }
            #expect(throws: PersistenceError.migrationFailed) { try ProteinStore(url: url) }
            let sql = try DatabaseQueue(path: url.path)
            try sql.read { db throws in
                #expect(try PersistenceSchema.checkVersion(db) == 1)
                #expect(try String.fetchOne(db, sql: "SELECT id FROM batches") == existing.id.uuidString)
                #expect(try String.fetchOne(db, sql: "SELECT name FROM sqlite_schema WHERE name = 'batches_updated'") == nil)
            }
        }
    }

    @Test func historyIndexOnlyDatabaseMigratesWithLegacyStartPolicy() throws {
        try withTemporaryDatabase { url in
            let existing = try sampleBatch()
            do {
                let sql = try DatabaseQueue(path: url.path)
                try PersistenceSchema.migrator.migrate(sql, upTo: "historyIndexes")
                try sql.write { db in try insertLegacyBatch(existing, into: db) }
            }
            let store = try ProteinStore(url: url)
            #expect(ProteinStore.currentSchemaVersion == 3)
            #expect(try store.batch(id: existing.id) == existing)
            #expect(try store.batch(id: existing.id)?.parameters.startPolicy == StartCodonPolicy.none)
            let sql = try DatabaseQueue(path: url.path)
            try sql.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT start_policy FROM batches") == "none")
                #expect(try Int.fetchOne(db, sql: "SELECT max(version) FROM schema_metadata") == 3)
            }
        }
    }

    @Test func newStoreAcceptsEmptyMigrationBookkeepingAfterInitialInterruption() throws {
        try withTemporaryDatabase { url in
            do {
                let sql = try DatabaseQueue(path: url.path)
                try sql.write { db in
                    try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                }
            }
            #expect(try ProteinStore(url: url).batchHistory().isEmpty)
        }
    }

    @Test func corruptFileAndFutureSchemaAreRejectedWithoutChangingBytes() throws {
        try withTemporaryDatabase { url in
            let invalid = Data(repeating: 0xFE, count: 1_024)
            try invalid.write(to: url)
            #expect(throws: PersistenceError.corruptedDatabase) { try ProteinStore(url: url) }
            #expect(try Data(contentsOf: url) == invalid)
        }
        try withTemporaryDatabase { url in
            _ = try ProteinStore(url: url)
            do {
                let sql = try DatabaseQueue(path: url.path)
                try sql.write { db in
                    try db.execute(sql: "INSERT INTO schema_metadata (version, migration) VALUES (99, 'a future version')")
                }
            }
            let original = try Data(contentsOf: url)
            #expect(throws: PersistenceError.unsupportedSchemaVersion(99)) { try ProteinStore(url: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: [1, 2, 3]) func startupRejectsMissingColumnBeforeWriting(version: Int) throws {
        try withTemporaryDatabase { url in
            var queued = try sampleBatch()
            queued.status = .queued
            do {
                let sql = try DatabaseQueue(path: url.path)
                try PersistenceSchema.migrator.migrate(sql, upTo: PersistenceSchema.migrations[version - 1])
                try sql.write { db in
                    if version < 3 {
                        try insertLegacyBatch(queued, into: db)
                    } else {
                        try StoredBatch(queued).insert(db)
                    }
                    try db.execute(sql: "ALTER TABLE records DROP COLUMN dna")
                    #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
                }
            }
            let original = try Data(contentsOf: url)
            #expect(throws: PersistenceError.incompatibleSchema) { try ProteinStore(url: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func startupRejectsMissingSchemaConstraintBeforeWriting() throws {
        try withTemporaryDatabase { url in
            var queued = try sampleBatch()
            queued.status = .queued
            try ProteinStore(url: url).saveBatch(queued)
            do {
                let sql = try DatabaseQueue(path: url.path)
                try sql.write { db in
                    try db.execute(sql: """
                        DROP TABLE presets;
                        CREATE TABLE presets (
                            id TEXT PRIMARY KEY NOT NULL,
                            name TEXT,
                            species TEXT NOT NULL,
                            stop_policy TEXT NOT NULL,
                            avoid TEXT NOT NULL,
                            created_at REAL NOT NULL
                        );
                        """)
                    #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
                }
            }
            let original = try Data(contentsOf: url)
            #expect(throws: PersistenceError.incompatibleSchema) { try ProteinStore(url: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func startupRejectsBrokenForeignKeyBeforeMutatingQueuedBatches() throws {
        try withTemporaryDatabase { url in
            var queued = try sampleBatch()
            queued.status = .queued
            try ProteinStore(url: url).saveBatch(queued)
            do {
                var config = Configuration()
                config.foreignKeysEnabled = false
                let sql = try DatabaseQueue(path: url.path, configuration: config)
                try sql.write { db in
                    try db.execute(sql: "UPDATE records SET batch_id = ? WHERE id = ?",
                                   arguments: [UUID().uuidString, queued.records[0].id.uuidString])
                }
            }
            let original = try Data(contentsOf: url)
            #expect(throws: PersistenceError.corruptedDatabase) { try ProteinStore(url: url) }
            #expect(try Data(contentsOf: url) == original)
        }
    }
}
