using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Application;

public enum ExportFormat { Fasta, ResultsCsv, AuditZip }

public static class LocalBatchExport
{
    public const int MaxBytes = 10 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8 = new(false);
    private static readonly JsonSerializerOptions AuditOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static byte[] Encode(Batch batch, ExportFormat format, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        byte[] bytes = format switch
        {
            ExportFormat.Fasta => Utf8.GetBytes(Fasta(batch.Records)),
            ExportFormat.ResultsCsv => Utf8.GetBytes(Csv(batch, cancellationToken)),
            ExportFormat.AuditZip => AuditZip(batch, cancellationToken),
            _ => throw new ArgumentOutOfRangeException(nameof(format))
        };
        CheckSize(bytes.Length);
        return bytes;
    }

    public static async Task WriteAsync(string path, byte[] bytes, CancellationToken cancellationToken = default)
    {
        CheckSize(bytes.Length);
        string fullPath = Path.GetFullPath(path);
        string temporary = Path.Combine(Path.GetDirectoryName(fullPath)!, $".codon-export-{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.Asynchronous))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporary, fullPath, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }

    private static string Fasta(IEnumerable<SequenceRecord> records)
    {
        var text = new StringBuilder();
        foreach (var record in records)
        {
            var name = new StringBuilder();
            bool space = false;
            foreach (var rune in record.Name.EnumerateRunes())
            {
                if (Rune.IsWhiteSpace(rune) || Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format)
                {
                    space = name.Length > 0;
                    continue;
                }
                if (space) name.Append(' ');
                name.Append(rune.Value == '>' ? "_" : rune.ToString());
                space = false;
            }
            text.Append('>').Append(name.Length == 0 ? $"record-{record.Position}" : name.ToString()).Append('\n');
            string sequence = record.OriginalSequence.Value;
            for (int start = 0; start < sequence.Length; start += 80)
                text.Append(sequence, start, Math.Min(80, sequence.Length - start)).Append('\n');
        }
        return text.ToString();
    }

    private static string Csv(Batch batch, CancellationToken token)
    {
        var text = new StringBuilder("Number,Name,Protein Sequence,Codon-Optimized DNA Sequence\r\n");
        int count = 0;
        foreach (var record in batch.Records.Where(record => record.Status == RecordStatus.Completed))
        {
            token.ThrowIfCancellationRequested();
            VerifiedDna result;
            try { result = DnaValidation.Reverify(record, batch.Parameters); }
            catch (DomainException) { continue; }
            text.Append((++count).ToString(CultureInfo.InvariantCulture)).Append(',').Append(CsvField(record.Name)).Append(',')
                .Append(record.OriginalSequence.Value).Append(',').Append(result.Dna).Append("\r\n");
        }
        if (count == 0) throw new InvalidOperationException("There are no verified DNA results to export.");
        return text.ToString();
    }

    private static string CsvField(string field)
    {
        string candidate = field.TrimStart(' ', '\t', '\r', '\n');
        if (candidate.Length > 0 && candidate[0] is '=' or '+' or '-' or '@') field = "'" + field;
        return field.IndexOfAny([',', '"', '\n', '\r', '\v', '\f', '\u0085', '\u2028', '\u2029']) >= 0
            ? '"' + field.Replace("\"", "\"\"", StringComparison.Ordinal) + '"' : field;
    }

    private static byte[] AuditZip(Batch batch, CancellationToken token)
    {
        var audit = new
        {
            schemaVersion = 1,
            id = Id(batch.Id),
            requestID = batch.RequestId,
            name = batch.Name,
            status = Wire(batch.Status),
            createdAt = Iso(batch.CreatedAt),
            updatedAt = Iso(batch.UpdatedAt),
            authorizedAt = batch.AuthorizedAt is { } time ? Iso(time) : null,
            recipient = batch.Endpoint.OriginalString,
            fingerprint = batch.Fingerprint,
            stopRequested = batch.StopRequested,
            host = batch.Parameters.Species.WireValue(),
            startCodonPolicy = JsonNamingPolicy.CamelCase.ConvertName(batch.Parameters.StartPolicy.ToString()),
            terminalStopPolicy = Wire(batch.Parameters.StopPolicy),
            motifs = batch.Parameters.Avoid.Motifs,
            records = batch.Records.Select(record => new
            {
                id = Id(record.Id), position = record.Position, name = record.Name, status = Wire(record.Status),
                originalProtein = record.OriginalSequence.Value, preparedProtein = record.Sequence.Value,
                inputSHA256 = record.InputSha256, dnaSHA256 = record.DnaSha256,
                checks = record.Checks is { } checks ? new
                {
                    basePairCount = checks.BasePairCount, aminoAcidCount = checks.AminoAcidCount, gcPercent = checks.GcPercent,
                    hasTerminalStop = checks.HasTerminalStop, checkedMotifCount = checks.CheckedMotifCount
                } : null,
                attempts = record.Attempts.Select(attempt => new
                {
                    id = Id(attempt.Id), number = attempt.Number, status = Wire(attempt.Status),
                    effect = attempt.Effect == RequestEffect.NotSubmitted ? "not_submitted" : Wire(attempt.Effect),
                    startedAt = Iso(attempt.StartedAt), finishedAt = attempt.FinishedAt is { } end ? Iso(end) : null,
                    elapsedMilliseconds = attempt.ElapsedMilliseconds, httpStatus = attempt.HttpStatus, payloadSHA256 = attempt.PayloadSha256
                })
            })
        };
        const string readme = "Codon ProteinFactory local batch audit\n\n" +
            "job.json contains batch, record, and attempt metadata. Response bodies and DNA are omitted.\n" +
            "input.fasta contains the original normalized protein sequences, in batch order.\n" +
            "Stored verification statistics describe sequence checks. Experimental expression was not assessed.\n";
        var members = new (string Name, byte[] Bytes)[]
        {
            ("job.json", JsonSerializer.SerializeToUtf8Bytes(audit, AuditOptions)),
            ("input.fasta", Utf8.GetBytes(Fasta(batch.Records))),
            ("README.txt", Utf8.GetBytes(readme))
        };
        CheckSize(members.Sum(member => (long)member.Bytes.Length));
        using var output = new MemoryStream();
        using (var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, bytes) in members)
            {
                token.ThrowIfCancellationRequested();
                var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
                entry.ExternalAttributes = unchecked((int)0x81a40000); // Unix regular file, 0644.
                using var item = entry.Open();
                item.Write(bytes);
            }
        }
        return output.ToArray();
    }

    private static string Wire<T>(T value) where T : struct, Enum => value.ToString().ToLowerInvariant();
    private static string Id(Guid value) => value.ToString("D").ToUpperInvariant();
    private static string Iso(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    private static void CheckSize(long size)
    {
        if (size > MaxBytes) throw new InvalidOperationException("The export exceeds 10 MiB.");
    }
}
