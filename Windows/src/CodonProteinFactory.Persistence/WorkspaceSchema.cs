using Microsoft.Data.Sqlite;

namespace CodonProteinFactory.Persistence;

internal static class WorkspaceSchema
{
    private const int Version = 1;

    public static void Initialize(SqliteConnection connection)
    {
        using var transaction = connection.BeginTransaction();
        int version = Convert.ToInt32(connection.Scalar(transaction, "PRAGMA user_version;"));
        if (version == 0)
        {
            long tables = (long)connection.Scalar(transaction, "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%';")!;
            if (tables != 0) throw new InvalidDataException("This file is not a Codon Protein Factory Windows database.");
            connection.Execute(transaction, Schema);
            connection.Execute(transaction, "PRAGMA user_version = 1;");
        }
        else if (version != Version)
        {
            throw new InvalidDataException($"Workspace schema {version} is unsupported by this version of the application.");
        }
        if (connection.Scalar(transaction, "PRAGMA quick_check;") is not string result || result != "ok" ||
            connection.Scalar(transaction, "PRAGMA foreign_key_check;") is not null)
            throw new InvalidDataException("The workspace database failed its integrity check.");
        transaction.Commit();
        connection.Execute(null, "PRAGMA journal_mode = WAL;");
    }

    private const string Schema = """
        CREATE TABLE batches (
            id TEXT PRIMARY KEY NOT NULL,
            request_id TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 0),
            metadata TEXT NOT NULL
        ) STRICT;
        CREATE TABLE records (
            id TEXT PRIMARY KEY NOT NULL,
            batch_id TEXT NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
            position INTEGER NOT NULL CHECK (position >= 1 AND position <= 200),
            metadata TEXT NOT NULL,
            UNIQUE (batch_id, position)
        ) STRICT;
        CREATE TABLE attempts (
            id TEXT PRIMARY KEY NOT NULL,
            record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
            number INTEGER NOT NULL CHECK (number >= 1 AND number <= 10),
            metadata TEXT NOT NULL,
            response BLOB CHECK (response IS NULL OR length(response) <= 1048576),
            UNIQUE (record_id, number)
        ) STRICT;
        CREATE TABLE presets (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('import', 'parameters')),
            name TEXT NOT NULL,
            metadata TEXT NOT NULL
        ) STRICT;
        CREATE INDEX batches_updated ON batches(updated_at DESC, id);
        CREATE INDEX batches_status_updated ON batches(status, updated_at DESC, id);
        CREATE INDEX batches_created ON batches(created_at DESC, id);
        CREATE INDEX presets_kind_name ON presets(kind, name);
        """;
}

internal static class SqlCommands
{
    public static SqliteCommand Command(this SqliteConnection connection, SqliteTransaction? tx, string sql,
        params (string Name, object? Value)[] args)
    {
        var command = connection.CreateCommand();
        command.Transaction = tx;
        command.CommandText = sql;
        foreach (var (name, value) in args) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command;
    }

    public static int Execute(this SqliteConnection connection, SqliteTransaction? tx, string sql,
        params (string Name, object? Value)[] args)
    {
        using var command = connection.Command(tx, sql, args);
        return command.ExecuteNonQuery();
    }

    public static object? Scalar(this SqliteConnection connection, SqliteTransaction? tx, string sql,
        params (string Name, object? Value)[] args)
    {
        using var command = connection.Command(tx, sql, args);
        return command.ExecuteScalar();
    }
}
