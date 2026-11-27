namespace CodonProteinFactory.Domain;

public enum BatchStatus { Prepared, Queued, Running, Completed, Partial, Failed, Stopped, Unknown }
public enum RecordStatus { Pending, Running, Completed, Failed, Unknown }
public enum AttemptStatus { Dispatching, Completed, Failed, Unknown }
public enum RequestEffect { Unknown, Completed, Rejected, NotSubmitted }

public sealed record RequestAttempt(Guid Id, int Number, DateTimeOffset StartedAt, string PayloadSha256)
{
    public DateTimeOffset? FinishedAt { get; init; }
    public AttemptStatus Status { get; init; } = AttemptStatus.Dispatching;
    public RequestEffect Effect { get; init; } = RequestEffect.Unknown;
    public int? HttpStatus { get; init; }
    public long? ElapsedMilliseconds { get; init; }
    public string? Error { get; init; }
    public int? ResponseLength { get; init; }
}

public sealed record SequenceRecord(Guid Id, Guid BatchId, int Position, string Name,
    ProteinSequence OriginalSequence, ProteinSequence Sequence, string InputSha256)
{
    public RecordStatus Status { get; init; } = RecordStatus.Pending;
    public string? Dna { get; init; }
    public string? DnaSha256 { get; init; }
    public DnaChecks? Checks { get; init; }
    public string? Error { get; init; }
    public IReadOnlyList<RequestAttempt> Attempts { get; init; } = Array.Empty<RequestAttempt>();
}

public sealed record Batch(Guid Id, string RequestId, string Name, OptimizationParameters Parameters,
    Uri Endpoint, string Fingerprint, IReadOnlyList<SequenceRecord> Records, DateTimeOffset CreatedAt)
{
    public static Uri ServiceEndpoint { get; } = new("https://www.ourproteinfactory.com/toDnaAjaxCodon");

    public DateTimeOffset UpdatedAt { get; init; } = CreatedAt;
    public DateTimeOffset? AuthorizedAt { get; init; }
    public BatchStatus Status { get; init; } = BatchStatus.Prepared;
    public bool StopRequested { get; init; }
    public string Message { get; init; } = string.Empty;
    public int OriginalSequenceLength => Records.Sum(record => record.OriginalSequence.Value.Length);
    public int SubmittedSequenceLength => Records.Sum(record => record.Sequence.Value.Length);
}

public sealed record SequenceRecordInput(string Name, string Sequence, int? SourceRow = null);
