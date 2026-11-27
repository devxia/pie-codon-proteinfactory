namespace CodonProteinFactory.Domain;

public static class BatchPreparation
{
    public static Batch Prepare(string name, IReadOnlyList<SequenceRecordInput> inputs,
        OptimizationParameters? parameters = null, string? requestId = null, DateTimeOffset? now = null)
    {
        string batchName = ValidateName(name, DomainLimits.MaxBatchNameLength)
            ?? throw new DomainException(DomainErrorCode.InvalidBatchName, "Enter a valid batch name.");
        requestId = ValidateName(requestId ?? Guid.NewGuid().ToString("D"), DomainLimits.MaxBatchNameLength)
            ?? throw new DomainException(DomainErrorCode.InvalidRequestId, "Invalid request ID.");
        if (inputs.Count is < 1 or > DomainLimits.MaxRecords)
            throw new DomainException(DomainErrorCode.RecordCount, $"A batch must contain 1 to {DomainLimits.MaxRecords} records.");

        parameters ??= new OptimizationParameters();
        Guid batchId = Guid.NewGuid();
        var records = new List<SequenceRecord>(inputs.Count);
        int total = 0;
        for (int index = 0; index < inputs.Count; index++)
        {
            int position = index + 1;
            var input = inputs[index];
            string recordName = ValidatedRecordName(input.Name)
                ?? throw new DomainException(DomainErrorCode.InvalidRecordName, $"Record {position} has an invalid name.", position, input.SourceRow);
            ProteinSequence original;
            ProteinSequence submitted;
            try
            {
                original = ProteinSequence.Parse(input.Sequence);
                submitted = original.Apply(parameters.StopPolicy);
            }
            catch (DomainException error)
            {
                throw new DomainException(error.Code, $"Record {position}: {error.Message}", position, input.SourceRow, error);
            }
            total += original.Value.Length;
            if (total > DomainLimits.MaxBatchLength)
                throw new DomainException(DomainErrorCode.BatchTooLong, $"Batch exceeds {DomainLimits.MaxBatchLength:N0} characters.");
            records.Add(new SequenceRecord(Guid.NewGuid(), batchId, position, recordName, original,
                submitted, Digests.Sha256(submitted.Value)));
        }
        Uri endpoint = Batch.ServiceEndpoint;
        string fingerprint = PreviewIntegrity.Fingerprint(batchName, records, parameters, endpoint);
        return new Batch(batchId, requestId, batchName, parameters, endpoint, fingerprint, records.AsReadOnly(), now ?? DateTimeOffset.UtcNow);
    }

    public static string? ValidatedRecordName(string raw) => ValidateName(raw, DomainLimits.MaxRecordNameLength);

    private static string? ValidateName(string raw, int maxLength)
    {
        if (raw.Length > maxLength || raw.Any(c => c <= 31 || c == 127)) return null;
        string trimmed = raw.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }
}
