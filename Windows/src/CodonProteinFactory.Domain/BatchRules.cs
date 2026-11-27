namespace CodonProteinFactory.Domain;

public sealed record BatchSummary(int Pending, int Running, int Completed, int Failed, int Unknown)
{
    public int Total => Pending + Running + Completed + Failed + Unknown;
    public int Done => Completed + Failed + Unknown;

    public static BatchSummary Count(IEnumerable<SequenceRecord> records)
    {
        var counts = records.GroupBy(record => record.Status).ToDictionary(group => group.Key, group => group.Count());
        return new BatchSummary(counts.GetValueOrDefault(RecordStatus.Pending), counts.GetValueOrDefault(RecordStatus.Running),
            counts.GetValueOrDefault(RecordStatus.Completed), counts.GetValueOrDefault(RecordStatus.Failed),
            counts.GetValueOrDefault(RecordStatus.Unknown));
    }

    public BatchStatus? StatusAfterExecution()
    {
        if (Unknown > 0) return BatchStatus.Unknown;
        if (Running > 0) return null;
        if (Completed > 0 && Completed == Total) return BatchStatus.Completed;
        if (Pending > 0) return BatchStatus.Stopped;
        return Completed > 0 ? BatchStatus.Partial : BatchStatus.Failed;
    }
}

public static class RetryPolicy
{
    public static IReadOnlyList<Guid> EligibleRecords(Batch batch, bool unknownConfirmed = false)
    {
        PreviewIntegrity.Verify(batch);
        if (batch.Status is BatchStatus.Prepared or BatchStatus.Queued or BatchStatus.Running)
            throw new DomainException(DomainErrorCode.InvalidBatchState, $"A {batch.Status.ToString().ToLowerInvariant()} batch cannot be retried.");
        if (batch.Records.FirstOrDefault(record => record.Status == RecordStatus.Running) is { } running)
            throw new DomainException(DomainErrorCode.RecordRunning, $"Record {running.Position} is still running.", running.Position);
        if (!unknownConfirmed && batch.Records.Any(record => record.Status == RecordStatus.Unknown))
            throw new DomainException(DomainErrorCode.UnknownRequiresConfirmation, "Confirm retry for records with unknown outcomes.");
        if (batch.Records.All(record => record.Status == RecordStatus.Completed))
            throw new DomainException(DomainErrorCode.NoPendingRecords, "There are no records to retry.");

        var eligible = new List<Guid>();
        foreach (var record in batch.Records)
        {
            if (record.Status == RecordStatus.Completed)
            {
                DnaValidation.Reverify(record, batch.Parameters);
                continue;
            }
            if (record.Attempts.Count >= DomainLimits.MaxAttempts || record.Attempts.LastOrDefault()?.Number >= DomainLimits.MaxAttempts)
                throw new DomainException(DomainErrorCode.AttemptLimit, $"Record {record.Position} reached the retry limit.", record.Position);
            eligible.Add(record.Id);
        }
        return eligible.AsReadOnly();
    }
}
