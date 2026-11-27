import GRDB

enum PersistenceSchema {
    static let migrations = ["initial", "historyIndexes", "startCodonPolicy"]
    static let version = migrations.count

    // Keep version 1 definitions stable when domain values or storage limits change.
    private static let initialSchema = [
        """
        CREATE TABLE schema_metadata (
            version INTEGER PRIMARY KEY,
            migration TEXT NOT NULL UNIQUE,
            applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """,
        """
        CREATE TABLE batches (
            id TEXT PRIMARY KEY NOT NULL,
            request_id TEXT NOT NULL,
            name TEXT NOT NULL,
            species TEXT NOT NULL,
            stop_policy TEXT NOT NULL,
            avoid TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            authorized_at REAL,
            status TEXT NOT NULL CHECK (status IN ('prepared', 'queued', 'running', 'completed', 'partial', 'failed', 'stopped', 'unknown')),
            stop_requested BOOLEAN NOT NULL CHECK (stop_requested IN (0, 1)),
            message TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE records (
            id TEXT PRIMARY KEY NOT NULL,
            batch_id TEXT NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK (position > 0),
            name TEXT NOT NULL,
            original_sequence TEXT NOT NULL,
            sequence TEXT NOT NULL,
            input_sha256 TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'failed', 'unknown')),
            dna TEXT,
            dna_sha256 TEXT,
            checks BLOB,
            error TEXT,
            UNIQUE (batch_id, position)
        )
        """,
        """
        CREATE TABLE attempts (
            id TEXT PRIMARY KEY NOT NULL,
            record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
            number INTEGER NOT NULL CHECK (number > 0),
            started_at REAL NOT NULL,
            finished_at REAL,
            payload_sha256 TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('dispatching', 'completed', 'failed', 'unknown')),
            effect TEXT NOT NULL CHECK (effect IN ('unknown', 'completed', 'rejected', 'not_submitted')),
            http_status INTEGER,
            elapsed_milliseconds INTEGER,
            response BLOB CHECK (response IS NULL OR (typeof(response) = 'blob' AND length(response) <= 1048576)),
            error TEXT,
            UNIQUE (record_id, number)
        )
        """,
        """
        CREATE TABLE presets (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            species TEXT NOT NULL,
            stop_policy TEXT NOT NULL,
            avoid TEXT NOT NULL,
            created_at REAL NOT NULL
        )
        """
    ]

    private static let historyIndexes = [
        "CREATE INDEX batches_updated ON batches(updated_at DESC, id)",
        "CREATE INDEX batches_status_updated ON batches(status, updated_at DESC, id)",
        "CREATE INDEX records_status ON records(status)",
        "CREATE INDEX attempts_dispatching ON attempts(record_id) WHERE status = 'dispatching'"
    ]

    private static let startCodonColumn =
        "start_policy TEXT NOT NULL DEFAULT 'none' CHECK (start_policy IN ('none', 'always', 'ifNotMethionine'))"
    private static let startCodonColumns = [
        "ALTER TABLE batches ADD COLUMN \(startCodonColumn)",
        "ALTER TABLE presets ADD COLUMN \(startCodonColumn)"
    ]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(migrations[0]) { db in
            try db.execute(sql: initialSchema.joined(separator: ";\n"))
            try recordMigration(1, in: db)
        }
        migrator.registerMigration(migrations[1]) { db in
            try db.execute(sql: historyIndexes.joined(separator: ";\n"))
            try recordMigration(2, in: db)
        }
        migrator.registerMigration(migrations[2]) { db in
            try db.execute(sql: startCodonColumns.joined(separator: ";\n"))
            try recordMigration(3, in: db)
        }
        return migrator
    }

    static func checkIntegrity(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "PRAGMA integrity_check(1)") == "ok",
              try Row.fetchOne(db, sql: "SELECT 1 FROM pragma_foreign_key_check LIMIT 1") == nil else {
            throw PersistenceError.corruptedDatabase
        }
    }

    static func checkVersion(_ db: Database) throws -> Int {
        guard try db.tableExists("schema_metadata") else {
            let objects = try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*' LIMIT 2")
            if objects.isEmpty { return 0 }
            guard objects == ["grdb_migrations"], try migrator.appliedIdentifiers(db).isEmpty else {
                throw PersistenceError.incompatibleSchema
            }
            return 0
        }

        let version = try Int.fetchOne(db, sql: "SELECT max(version) FROM schema_metadata") ?? 0
        guard (1...Self.version).contains(version) else {
            throw PersistenceError.unsupportedSchemaVersion(version)
        }
        let history = try String.fetchAll(db, sql: "SELECT migration FROM schema_metadata ORDER BY version LIMIT ?", arguments: [Self.version + 1])
        guard history == Array(migrations.prefix(version)),
              try Int.fetchAll(db, sql: "SELECT version FROM schema_metadata ORDER BY version LIMIT ?", arguments: [Self.version + 1]) == Array(1...version),
              try migrator.appliedIdentifiers(db) == Set(history) else {
            throw PersistenceError.incompatibleSchema
        }
        // SQLite retains the CREATE statements for these objects. Compare with the same DDL
        // used by the migrations so columns, keys, foreign keys and CHECK clauses are covered.
        let definitions = try String.fetchSet(db, sql: """
            SELECT sql FROM sqlite_schema WHERE type IN ('table', 'index') AND sql IS NOT NULL
            """)
        var required = initialSchema
        if version >= 2 { required += historyIndexes }
        if version >= 3 {
            // SQLite rewrites ALTER TABLE into the table's final CREATE statement in sqlite_schema.
            // Compare that full definition, including the added NOT NULL, DEFAULT and CHECK clauses.
            required = try required.map { definition in
                guard definition.hasPrefix("CREATE TABLE batches ") || definition.hasPrefix("CREATE TABLE presets ") else {
                    return definition
                }
                let closing = "\n)"
                guard definition.hasSuffix(closing) else { throw PersistenceError.incompatibleSchema }
                return String(definition.dropLast(closing.count)) + "\n, \(startCodonColumn))"
            }
        }
        guard definitions.isSuperset(of: required) else { throw PersistenceError.incompatibleSchema }
        return version
    }

    private static func recordMigration(_ version: Int, in db: Database) throws {
        try db.execute(sql: "INSERT INTO schema_metadata (version, migration) VALUES (?, ?)", arguments: [version, migrations[version - 1]])
    }

}
