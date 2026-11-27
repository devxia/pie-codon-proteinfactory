using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace CodonProteinFactory.Domain;

public static class Digests
{
    public static string Sha256(string text) => Sha256(Encoding.UTF8.GetBytes(text));
    public static string Sha256(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
}

public static class PreviewIntegrity
{
    internal static string Fingerprint(string name, IReadOnlyList<SequenceRecord> records,
        OptimizationParameters parameters, Uri endpoint)
    {
        var fields = new StringBuilder();
        void Append(string field)
        {
            fields.Append(Encoding.UTF8.GetByteCount(field).ToString(CultureInfo.InvariantCulture));
            fields.Append(':');
            fields.Append(field);
        }

        Append(parameters.StartPolicy == StartCodonPolicy.None ? "ProteinDomain.preview.v1" : "ProteinDomain.preview.v2");
        Append(name);
        Append(endpoint.AbsoluteUri);
        Append(parameters.Species.WireValue());
        if (parameters.StartPolicy != StartCodonPolicy.None)
            Append(parameters.StartPolicy == StartCodonPolicy.Always ? "always" : "ifNotMethionine");
        Append(parameters.StopPolicy == StopPolicy.Add ? "add" : "preserve");
        Append(parameters.Avoid.WireValue);
        Append(records.Count.ToString(CultureInfo.InvariantCulture));
        foreach (var record in records)
        {
            Append(record.Name);
            Append(record.OriginalSequence.Value);
            Append(record.Sequence.Value);
        }
        return Digests.Sha256(fields.ToString());
    }

    public static void Verify(Batch batch)
    {
        if (batch.Endpoint.OriginalString != Batch.ServiceEndpoint.OriginalString)
            throw new DomainException(DomainErrorCode.EndpointMismatch, "Draft receiver does not match the configured service.");

        var ids = new HashSet<Guid>();
        for (int index = 0; index < batch.Records.Count; index++)
        {
            int position = index + 1;
            var record = batch.Records[index];
            if (record.Position != position || record.BatchId != batch.Id || !ids.Add(record.Id))
                throw new DomainException(DomainErrorCode.RecordLayoutMismatch, $"Record {position} does not match the draft.", position);
            if (Digests.Sha256(record.Sequence.Value) != record.InputSha256)
                throw new DomainException(DomainErrorCode.InputHashMismatch, $"Record {position} has changed.", position);
        }
        if (batch.Fingerprint != Fingerprint(batch.Name, batch.Records, batch.Parameters, batch.Endpoint))
            throw new DomainException(DomainErrorCode.FingerprintMismatch, "Draft content has changed since it was prepared.");
    }
}
