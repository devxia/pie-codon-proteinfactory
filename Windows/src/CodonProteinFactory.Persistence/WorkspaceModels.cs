using CodonProteinFactory.Domain;
using CodonProteinFactory.SequenceIO;

namespace CodonProteinFactory.Persistence;

public sealed record BatchSnapshot(Batch Batch, long Revision);
public sealed record AttemptBody(Guid RecordId, Guid AttemptId, byte[]? Response);
public sealed record AttemptResponse(bool Exists, byte[]? Body);
public sealed record BatchHistoryRow(Guid Id, string Name, BatchStatus Status, DateTimeOffset UpdatedAt, int RecordCount,
    DateTimeOffset CreatedAt);
public enum HistorySort { UpdatedNewest, CreatedNewest, Name }
public sealed record HistoryQuery(string Search = "", BatchStatus? Status = null, DateTimeOffset? From = null,
    DateTimeOffset? Before = null, HistorySort Sort = HistorySort.UpdatedNewest, int Offset = 0, int Limit = 100);
public sealed record ParameterPreset(Guid Id, string Name, OptimizationParameters Parameters);

public sealed class WorkspaceConflictException() : InvalidOperationException("The saved batch changed. Refresh and try again.");

public interface IWorkspaceStore
{
    BatchSnapshot Insert(Batch batch);
    BatchSnapshot Update(BatchSnapshot snapshot, Batch batch, AttemptBody? body = null);
    BatchSnapshot? Load(Guid batchId);
    IReadOnlyList<BatchHistoryRow> History(HistoryQuery query);
    bool Delete(Guid batchId);
    AttemptResponse ReadResponse(Guid recordId, Guid attemptId);
}
