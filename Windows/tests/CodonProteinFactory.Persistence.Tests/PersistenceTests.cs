using System.IO.Compression;
using System.Text;
using System.Text.Json;
using CodonProteinFactory.Application;
using CodonProteinFactory.Domain;
using CodonProteinFactory.SequenceIO;
using Microsoft.Data.Sqlite;

namespace CodonProteinFactory.Persistence.Tests;

public sealed class PersistenceTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "CodonFactoryStoreTests-" + Guid.NewGuid().ToString("N"));

    [Fact]
    public void ReopensVerifiedResultAndLoadsOnlyOwnedAttemptBody()
    {
        var store = new WorkspaceStore(root);
        var prepared = store.Insert(Prepare("Reopen"));
        var receipt = "{\"success\": 1, \"seq\": \"GCT\"}"u8.ToArray();
        var completed = Complete(prepared.Batch, receipt.Length);
        var record = completed.Records[0];
        var attempt = record.Attempts[0];
        store.Update(prepared, completed, new AttemptBody(record.Id, attempt.Id, receipt));
        store.Checkpoint();

        var reopened = new WorkspaceStore(root);
        Assert.Equal(BatchStatus.Completed, Assert.Single(reopened.History(new HistoryQuery("reOPEN"))).Status);
        var restored = reopened.Load(completed.Id)!;
        Assert.Equal(1, restored.Revision);
        Assert.Equal("GCT", DnaValidation.Reverify(restored.Batch.Records[0], restored.Batch.Parameters).Dna);
        Assert.Equal(receipt.Length, restored.Batch.Records[0].Attempts[0].ResponseLength);
        Assert.Equal(receipt, reopened.ReadResponse(record.Id, attempt.Id).Body);
        Assert.False(reopened.ReadResponse(Guid.NewGuid(), attempt.Id).Exists);
        Assert.True(reopened.Delete(completed.Id));
        Assert.False(reopened.ReadResponse(record.Id, attempt.Id).Exists);
    }

    [Fact]
    public void RejectsStaleWriterAndRollsBackFailedChildInsert()
    {
        var store = new WorkspaceStore(root);
        var first = store.Insert(Prepare("First"));
        var second = new WorkspaceStore(root);
        second.Update(first, first.Batch with { Message = "Written once" });
        Assert.Throws<WorkspaceConflictException>(() => store.Update(first, first.Batch with { Message = "Stale" }));
        var current = store.Load(first.Batch.Id)!;
        Assert.Equal("Written once", current.Batch.Message);
        var record = current.Batch.Records[0] with
        {
            Attempts = [new RequestAttempt(Guid.NewGuid(), 0, DateTimeOffset.UtcNow, Digests.Sha256("payload"))]
        };
        Assert.Throws<SqliteException>(() => store.Update(current, current.Batch with { Status = BatchStatus.Running, Records = [record] }));
        var restored = store.Load(first.Batch.Id)!;
        Assert.Equal(1, restored.Revision);
        Assert.Equal(BatchStatus.Prepared, restored.Batch.Status);
        Assert.Empty(restored.Batch.Records[0].Attempts);
    }

    [Fact]
    public void SeparatesEmptyBodyFromAbsentBodyAndLimitsBlobSize()
    {
        var store = new WorkspaceStore(root);
        var prepared = store.Insert(Prepare("Body"));
        var completed = Complete(prepared.Batch, null);
        var record = completed.Records[0];
        var attempt = record.Attempts[0];
        var written = store.Update(prepared, completed);
        Assert.True(store.ReadResponse(record.Id, attempt.Id).Exists);
        Assert.Null(store.ReadResponse(record.Id, attempt.Id).Body);
        var empty = completed with { Records = [record with { Attempts = [attempt with { ResponseLength = 0 }] }] };
        var updated = store.Update(written, empty, new AttemptBody(record.Id, attempt.Id, []));
        Assert.Empty(store.ReadResponse(record.Id, attempt.Id).Body!);
        Assert.Throws<ArgumentOutOfRangeException>(() => store.Update(updated, empty,
            new AttemptBody(record.Id, attempt.Id, new byte[WorkspaceStore.MaxResponseBytes + 1])));
    }

    [Fact]
    public void SavesPresetsAndBacksUpConsistentDatabase()
    {
        var store = new WorkspaceStore(root);
        var imported = new ImportPreset(Guid.NewGuid(), "Mapping", new ColumnMapping(1, true, 0, 2));
        var parameters = new ParameterPreset(Guid.NewGuid(), "Settings", new OptimizationParameters { Avoid = AvoidMotifs.Parse("GCT") });
        store.Save(imported);
        store.Save(parameters);
        var draft = store.Insert(Prepare("Backup"));
        string backup = Path.Combine(root, "backup");
        Directory.CreateDirectory(backup);
        store.Backup(Path.Combine(backup, "Workspace.sqlite"));
        var restored = new WorkspaceStore(backup);
        Assert.NotNull(restored.Load(draft.Batch.Id));
        Assert.Equal(imported, Assert.Single(restored.ImportPresets()));
        Assert.Equal(parameters, Assert.Single(restored.ParameterPresets()));
        Assert.True(restored.DeletePreset(imported.Id));
        Assert.Single(store.ImportPresets());
    }

    [Fact]
    public void RejectsUnknownSchemaWithoutOverwritingIt()
    {
        var store = new WorkspaceStore(root);
        using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = store.DatabasePath, Pooling = false }.ToString());
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "PRAGMA user_version = 99;";
        command.ExecuteNonQuery();
        Assert.Throws<InvalidDataException>(() => new WorkspaceStore(root));
        command.CommandText = "PRAGMA user_version;";
        Assert.Equal(99L, command.ExecuteScalar());
    }

    [Fact]
    public async Task ExportsOnlyReverifiedDnaAndAtomicCsvWithFormulaProtection()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "windows-formula-protection.json")));
        var value = fixture.RootElement;
        var batch = Complete(Prepare("Export", value.GetProperty("name").GetString()!), null);
        var bad = batch with { Records = [batch.Records[0] with { DnaSha256 = Digests.Sha256("wrong") }] };
        Assert.Throws<InvalidOperationException>(() => LocalBatchExport.Encode(bad, ExportFormat.ResultsCsv));
        byte[] csv = LocalBatchExport.Encode(batch, ExportFormat.ResultsCsv);
        Assert.Equal(value.GetProperty("storedName").GetString(), batch.Records[0].Name);
        string name = value.GetProperty("csvName").GetString()!;
        Assert.Equal($"Number,Name,Protein Sequence,Codon-Optimized DNA Sequence\r\n1,{name},A,GCT\r\n", Encoding.UTF8.GetString(csv));
        Directory.CreateDirectory(root);
        string output = Path.Combine(root, "result.csv");
        File.WriteAllText(output, "old");
        await LocalBatchExport.WriteAsync(output, csv);
        Assert.Equal(csv, File.ReadAllBytes(output));
        Assert.Single(Directory.GetFiles(root));
    }

    [Fact]
    public void AuditZipOmitsDnaAndResponseAndUsesFixedFileEntries()
    {
        var batch = Complete(Prepare("Audit", " A > sample "), 6);
        using var zip = new ZipArchive(new MemoryStream(LocalBatchExport.Encode(batch, ExportFormat.AuditZip)));
        Assert.Equal(["job.json", "input.fasta", "README.txt"], zip.Entries.Select(entry => entry.FullName));
        using var json = JsonDocument.Parse(zip.Entries[0].Open());
        var record = json.RootElement.GetProperty("records")[0];
        Assert.False(record.TryGetProperty("dna", out _));
        Assert.True(record.TryGetProperty("dnaSHA256", out _));
        Assert.False(record.GetProperty("attempts")[0].TryGetProperty("response", out _));
        using var fasta = new StreamReader(zip.Entries[1].Open());
        Assert.Equal(">A _ sample\nA\n", fasta.ReadToEnd());
    }

    private static Batch Prepare(string batchName, string recordName = "Sample") =>
        BatchPreparation.Prepare(batchName, [new(recordName, "A")]);

    private static Batch Complete(Batch batch, int? bodyLength)
    {
        var record = batch.Records[0];
        var verified = DnaValidation.Verify("GCT", record.Sequence);
        var attempt = new RequestAttempt(Guid.NewGuid(), 1, DateTimeOffset.UtcNow, Digests.Sha256("payload"))
        {
            Status = AttemptStatus.Completed, Effect = RequestEffect.Completed, ResponseLength = bodyLength, HttpStatus = 200
        };
        return batch with { Status = BatchStatus.Completed, Records = [record with
        {
            Status = RecordStatus.Completed, Dna = verified.Dna, DnaSha256 = verified.Sha256, Checks = verified.Checks, Attempts = [attempt]
        }] };
    }

    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
}
