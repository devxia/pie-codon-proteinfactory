using CodonProteinFactory.Domain;
using CodonProteinFactory.SequenceIO;
using static CodonProteinFactory.Persistence.WorkspaceMetadata;

namespace CodonProteinFactory.Persistence;

public sealed partial class WorkspaceStore
{
    public BatchSnapshot? Load(Guid batchId)
    {
        using var connection = Open();
        using var transaction = connection.BeginTransaction(deferred: true);
        Batch batch;
        long revision;
        using (var command = connection.Command(transaction, """
            SELECT request_id, name, status, created_at, updated_at, revision, metadata FROM batches WHERE id = $id;
            """, ("$id", batchId)))
        using (var reader = command.ExecuteReader())
        {
            if (!reader.Read()) return null;
            var data = Decode<BatchData>(reader.GetString(6));
            revision = reader.GetInt64(5);
            batch = new Batch(batchId, reader.GetString(0), reader.GetString(1), data.Parameters.Restore(), new Uri(data.Endpoint),
                data.Fingerprint, [], ParseTime(reader.GetString(3)))
            {
                Status = Enum.Parse<BatchStatus>(reader.GetString(2), ignoreCase: true),
                UpdatedAt = ParseTime(reader.GetString(4)), AuthorizedAt = data.AuthorizedAt,
                StopRequested = data.StopRequested, Message = data.Message
            };
        }

        var attempts = new Dictionary<Guid, List<RequestAttempt>>();
        using (var command = connection.Command(transaction, """
            SELECT a.record_id,a.metadata FROM attempts a JOIN records r ON r.id = a.record_id
            WHERE r.batch_id = $id ORDER BY r.position, a.number;
            """, ("$id", batchId)))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                Guid id = reader.GetGuid(0);
                if (!attempts.TryGetValue(id, out var list)) attempts.Add(id, list = []);
                list.Add(Decode<RequestAttempt>(reader.GetString(1)));
            }
        }
        var records = new List<SequenceRecord>();
        using (var command = connection.Command(transaction, "SELECT id, position, metadata FROM records WHERE batch_id = $id ORDER BY position;", ("$id", batchId)))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                Guid id = reader.GetGuid(0);
                records.Add(Decode<RecordData>(reader.GetString(2)).Restore(id, batchId, reader.GetInt32(1), attempts.GetValueOrDefault(id)?.AsReadOnly() ?? (IReadOnlyList<RequestAttempt>)[]));
            }
        }
        transaction.Commit();
        return new BatchSnapshot(batch with { Records = records.AsReadOnly() }, revision);
    }

    public IReadOnlyList<BatchHistoryRow> History(HistoryQuery query)
    {
        if (query.Limit is < 1 or > 200 || query.Offset < 0) throw new ArgumentOutOfRangeException(nameof(query));
        using var connection = Open();
        connection.CreateFunction<string, string, bool>("name_matches", (name, search) => name.Contains(search, StringComparison.OrdinalIgnoreCase), isDeterministic: true);
        string order = query.Sort switch
        {
            HistorySort.UpdatedNewest => "updated_at DESC, id",
            HistorySort.CreatedNewest => "created_at DESC, id",
            HistorySort.Name => "name COLLATE NOCASE, id",
            _ => throw new ArgumentOutOfRangeException(nameof(query))
        };
        using var command = connection.Command(null, $"""
            SELECT id, name, status, updated_at, (SELECT count(*) FROM records r WHERE r.batch_id = b.id), created_at
            FROM batches b WHERE ($status IS NULL OR status = $status)
              AND ($from IS NULL OR created_at >= $from) AND ($before IS NULL OR created_at < $before)
              AND ($search = '' OR name_matches(name, $search)) ORDER BY {order} LIMIT $limit OFFSET $offset;
            """, ("$status", query.Status is { } status ? Status(status) : null), ("$from", query.From is { } from ? Time(from) : null),
            ("$before", query.Before is { } before ? Time(before) : null), ("$search", query.Search.Trim()),
            ("$limit", query.Limit), ("$offset", query.Offset));
        using var reader = command.ExecuteReader();
        var rows = new List<BatchHistoryRow>();
        while (reader.Read()) rows.Add(new BatchHistoryRow(reader.GetGuid(0), reader.GetString(1), Enum.Parse<BatchStatus>(reader.GetString(2), true),
            ParseTime(reader.GetString(3)), reader.GetInt32(4), ParseTime(reader.GetString(5))));
        return rows.AsReadOnly();
    }

    public IReadOnlyList<ImportPreset> ImportPresets() => Presets("import", (id, name, data) => new ImportPreset(id, name, Decode<ColumnMapping>(data)));
    public IReadOnlyList<ParameterPreset> ParameterPresets() => Presets("parameters", (id, name, data) => new ParameterPreset(id, name, Decode<Parameters>(data).Restore()));
    public void Save(ImportPreset preset) => SavePreset(preset.Id, "import", preset.Name, Encode(preset.Mapping));
    public void Save(ParameterPreset preset) => SavePreset(preset.Id, "parameters", preset.Name, Encode(Parameters.From(preset.Parameters)));

    public bool DeletePreset(Guid id)
    {
        using var connection = Open();
        return connection.Execute(null, "DELETE FROM presets WHERE id = $id;", ("$id", id)) == 1;
    }

    private IReadOnlyList<T> Presets<T>(string kind, Func<Guid, string, string, T> restore)
    {
        using var connection = Open();
        using var command = connection.Command(null, "SELECT id, name, metadata FROM presets WHERE kind = $kind ORDER BY name COLLATE NOCASE, id;", ("$kind", kind));
        using var reader = command.ExecuteReader();
        var result = new List<T>();
        while (reader.Read()) result.Add(restore(reader.GetGuid(0), reader.GetString(1), reader.GetString(2)));
        return result.AsReadOnly();
    }

    private void SavePreset(Guid id, string kind, string name, string data)
    {
        string validated = BatchPreparation.ValidatedRecordName(name) ?? throw new ArgumentException("Enter a valid preset name.", nameof(name));
        using var connection = Open();
        int updated = connection.Execute(null, """
            INSERT INTO presets(id, kind, name, metadata) VALUES ($id, $kind, $name, $data)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, metadata = excluded.metadata WHERE presets.kind = excluded.kind;
            """, ("$id", id), ("$kind", kind), ("$name", validated), ("$data", data));
        if (updated != 1) throw new WorkspaceConflictException();
    }
}
