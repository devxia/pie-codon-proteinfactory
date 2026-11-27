using CodonProteinFactory.Domain;
using CodonProteinFactory.SequenceIO;
using Microsoft.Data.Sqlite;
using static CodonProteinFactory.Persistence.WorkspaceMetadata;

namespace CodonProteinFactory.Persistence;

public sealed partial class WorkspaceStore : IWorkspaceStore
{
    public const int MaxResponseBytes = 1_048_576;
    private readonly string connectionString;

    public WorkspaceStore(string directory)
    {
        DirectoryPath = Path.GetFullPath(directory);
        Directory.CreateDirectory(DirectoryPath);
        DatabasePath = Path.Combine(DirectoryPath, "Workspace.sqlite");
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath, ForeignKeys = true, DefaultTimeout = 5, Pooling = false
        }.ToString();
        using var connection = Open();
        WorkspaceSchema.Initialize(connection);
    }

    public string DirectoryPath { get; }
    public string DatabasePath { get; }
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Codon ProteinFactory");

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection(connectionString);
        try { connection.Open(); return connection; }
        catch { connection.Dispose(); throw; }
    }

    public BatchSnapshot Insert(Batch batch)
    {
        PreviewIntegrity.Verify(batch);
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        connection.Execute(transaction, """
            INSERT INTO batches(id, request_id, name, status, created_at, updated_at, revision, metadata)
            VALUES ($id, $request, $name, $status, $created, $updated, 0, $data);
            """, ("$id", batch.Id), ("$request", batch.RequestId), ("$name", batch.Name), ("$status", Status(batch.Status)),
            ("$created", Time(batch.CreatedAt)), ("$updated", Time(batch.UpdatedAt)), ("$data", Encode(BatchData.From(batch))));
        SaveRecords(connection, transaction, batch, oldBatch: null);
        transaction.Commit();
        return new BatchSnapshot(batch, 0);
    }

    public BatchSnapshot Update(BatchSnapshot snapshot, Batch batch, AttemptBody? body = null)
    {
        var previous = snapshot.Batch;
        if (previous.Id != batch.Id || previous.RequestId != batch.RequestId || previous.Fingerprint != batch.Fingerprint ||
            previous.Name != batch.Name || previous.CreatedAt != batch.CreatedAt || previous.Records.Count != batch.Records.Count ||
            !previous.Records.Select(r => r.Id).SequenceEqual(batch.Records.Select(r => r.Id)))
            throw new ArgumentException("An update cannot replace a saved draft's identity.", nameof(batch));
        PreviewIntegrity.Verify(batch);
        if (body?.Response?.Length > MaxResponseBytes) throw new ArgumentOutOfRangeException(nameof(body));
        if (body is not null)
        {
            var owner = batch.Records.SingleOrDefault(record => record.Id == body.RecordId);
            var attempt = owner?.Attempts.SingleOrDefault(item => item.Id == body.AttemptId);
            if (attempt is null || attempt.ResponseLength != body.Response?.Length)
                throw new ArgumentException("Attempt body does not match its receipt metadata.", nameof(body));
        }
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        int changed = connection.Execute(transaction, """
            UPDATE batches SET status = $status, updated_at = $updated, metadata = $data, revision = revision + 1
            WHERE id = $id AND revision = $revision;
            """, ("$status", Status(batch.Status)), ("$updated", Time(batch.UpdatedAt)), ("$data", Encode(BatchData.From(batch))),
            ("$id", batch.Id), ("$revision", snapshot.Revision));
        if (changed != 1) throw new WorkspaceConflictException();
        SaveRecords(connection, transaction, batch, previous);
        if (body is not null)
        {
            int written = connection.Execute(transaction, "UPDATE attempts SET response = $data WHERE id = $id AND record_id = $record;",
                ("$data", body.Response), ("$id", body.AttemptId), ("$record", body.RecordId));
            if (written != 1) throw new WorkspaceConflictException();
        }
        transaction.Commit();
        return new BatchSnapshot(batch, snapshot.Revision + 1);
    }

    private static void SaveRecords(SqliteConnection connection, SqliteTransaction transaction, Batch batch, Batch? oldBatch)
    {
        for (int index = 0; index < batch.Records.Count; index++)
        {
            var record = batch.Records[index];
            var oldRecord = oldBatch?.Records[index];
            if (ReferenceEquals(record, oldRecord)) continue;
            int changed = connection.Execute(transaction, """
                INSERT INTO records(id, batch_id, position, metadata) VALUES ($id, $batch, $position, $data)
                ON CONFLICT(id) DO UPDATE SET metadata = excluded.metadata
                WHERE records.batch_id = excluded.batch_id AND records.position = excluded.position;
                """, ("$id", record.Id), ("$batch", batch.Id), ("$position", record.Position), ("$data", Encode(RecordData.From(record))));
            if (changed != 1) throw new WorkspaceConflictException();

            if (oldRecord is not null && !oldRecord.Attempts.Select(item => item.Id)
                .SequenceEqual(record.Attempts.Take(oldRecord.Attempts.Count).Select(item => item.Id)))
                throw new InvalidDataException("Attempt history cannot be removed or reordered.");
            for (int i = 0; i < record.Attempts.Count; i++)
            {
                var attempt = record.Attempts[i];
                if (oldRecord?.Attempts.ElementAtOrDefault(i) == attempt) continue;
                changed = connection.Execute(transaction, """
                    INSERT INTO attempts(id, record_id, number, metadata) VALUES ($id, $record, $number, $data)
                    ON CONFLICT(id) DO UPDATE SET metadata = excluded.metadata
                    WHERE attempts.record_id = excluded.record_id AND attempts.number = excluded.number;
                    """, ("$id", attempt.Id), ("$record", record.Id), ("$number", attempt.Number), ("$data", Encode(attempt)));
                if (changed != 1) throw new WorkspaceConflictException();
            }
        }
    }

    public bool Delete(Guid batchId)
    {
        using var connection = Open();
        return connection.Execute(null, "DELETE FROM batches WHERE id = $id AND status NOT IN ('running','queued');", ("$id", batchId)) == 1;
    }

    public AttemptResponse ReadResponse(Guid recordId, Guid attemptId)
    {
        using var connection = Open();
        object? value = connection.Scalar(null, "SELECT response FROM attempts WHERE record_id = $record AND id = $attempt;",
            ("$record", recordId), ("$attempt", attemptId));
        return new AttemptResponse(value is not null, value as byte[]);
    }

    public void Backup(string destination)
    {
        if (File.Exists(destination)) throw new IOException("The backup destination already exists.");
        using var source = Open();
        using var output = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString());
        output.Open();
        source.BackupDatabase(output);
    }

    public void Checkpoint()
    {
        using var connection = Open();
        connection.Execute(null, "PRAGMA wal_checkpoint(TRUNCATE);");
    }
}
