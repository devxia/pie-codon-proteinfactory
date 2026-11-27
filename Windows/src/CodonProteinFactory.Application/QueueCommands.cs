using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;

namespace CodonProteinFactory.Application;

public enum QueueErrorCode { Closed, StorageFailure, Capacity, InvalidDraft, Duplicate, MissingBatch, StaleConfirmation }

public sealed class QueueException(QueueErrorCode code, string message, Exception? inner = null) : InvalidOperationException(message, inner)
{
    public QueueErrorCode Code { get; } = code;
}

public sealed class ConfirmedUnknownRetry
{
    public ConfirmedUnknownRetry(Batch confirmedBatch)
    {
        BatchId = confirmedBatch.Id;
        Attempts = Capture(confirmedBatch);
    }

    public Guid BatchId { get; }
    private Dictionary<Guid, Guid[]> Attempts { get; }

    internal bool Matches(Batch batch)
    {
        var current = Capture(batch);
        return Attempts.Count > 0 && Attempts.Count == current.Count && Attempts.All(pair =>
            current.TryGetValue(pair.Key, out var ids) && pair.Value.SequenceEqual(ids));
    }

    private static Dictionary<Guid, Guid[]> Capture(Batch batch) => batch.Records.Where(record => record.Status == RecordStatus.Unknown)
        .ToDictionary(record => record.Id, record => record.Attempts.Select(attempt => attempt.Id).ToArray());
}

public static class QueueRecovery
{
    public static void Recover(IWorkspaceStore store, TimeProvider clock)
    {
        foreach (var status in new[] { BatchStatus.Running, BatchStatus.Queued })
        {
            while (store.History(new HistoryQuery(Status: status, Limit: 200)) is { Count: > 0 } pending)
            {
                foreach (var item in pending)
                {
                    var snapshot = store.Load(item.Id) ?? throw new WorkspaceConflictException();
                    DateTimeOffset now = clock.GetUtcNow();
                    var records = snapshot.Batch.Records.Select(record =>
                    {
                        if (record.Status != RecordStatus.Running && !record.Attempts.Any(attempt => attempt.Status == AttemptStatus.Dispatching)) return record;
                        return record with
                        {
                            Status = RecordStatus.Unknown, Error = "interrupted_dispatch",
                            Attempts = record.Attempts.Select(attempt => attempt.Status == AttemptStatus.Dispatching
                                ? attempt with { Status = AttemptStatus.Unknown, Effect = RequestEffect.Unknown, FinishedAt = now, Error = "interrupted_dispatch" }
                                : attempt).ToArray()
                        };
                    }).ToArray();
                    var summary = BatchSummary.Count(records);
                    BatchStatus outcome = status == BatchStatus.Queued && summary.Unknown == 0 ? BatchStatus.Stopped
                        : summary.StatusAfterExecution() ?? BatchStatus.Unknown;
                    store.Update(snapshot, snapshot.Batch with
                    {
                        Status = outcome, Records = records, StopRequested = true, UpdatedAt = now, Message = "recovered_after_interruption"
                    });
                }
            }
        }
    }
}
