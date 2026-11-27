using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Persistence;

internal static class WorkspaceMetadata
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) }
    };

    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Options);
    public static T Decode<T>(string text) => JsonSerializer.Deserialize<T>(text, Options) ?? throw new InvalidDataException("Missing workspace metadata.");
    public static string Time(DateTimeOffset time) => time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
    public static DateTimeOffset ParseTime(string value) => DateTimeOffset.ParseExact(value, "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture,
        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
    public static string Status(BatchStatus status) => status.ToString().ToLowerInvariant();

    public sealed record Parameters(string Species, StartCodonPolicy StartPolicy, StopPolicy StopPolicy, string Avoid)
    {
        public static Parameters From(OptimizationParameters parameters) => new(parameters.Species.WireValue(), parameters.StartPolicy,
            parameters.StopPolicy, parameters.Avoid.WireValue);

        public OptimizationParameters Restore() => new()
        {
            Species = Enum.GetValues<Species>().Single(value => value.WireValue() == Species),
            StartPolicy = StartPolicy,
            StopPolicy = StopPolicy,
            Avoid = AvoidMotifs.FromWireValue(Avoid)
        };
    }

    public sealed record BatchData(Parameters Parameters, string Endpoint, string Fingerprint,
        DateTimeOffset? AuthorizedAt, bool StopRequested, string Message)
    {
        public static BatchData From(Batch batch) => new(Parameters.From(batch.Parameters), batch.Endpoint.OriginalString,
            batch.Fingerprint, batch.AuthorizedAt?.ToUniversalTime(), batch.StopRequested, batch.Message);
    }

    public sealed record RecordData(string Name, string Original, string Submitted, string InputSha256, RecordStatus Status,
        string? Dna, string? DnaSha256, DnaChecks? Checks, string? Error)
    {
        public static RecordData From(SequenceRecord record) => new(record.Name, record.OriginalSequence.Value, record.Sequence.Value,
            record.InputSha256, record.Status, record.Dna, record.DnaSha256, record.Checks, record.Error);

        public SequenceRecord Restore(Guid id, Guid batchId, int position, IReadOnlyList<RequestAttempt> attempts) =>
            new(id, batchId, position, Name, ProteinSequence.Parse(Original), ProteinSequence.Parse(Submitted), InputSha256)
            {
                Status = Status, Dna = Dna, DnaSha256 = DnaSha256, Checks = Checks, Error = Error, Attempts = attempts
            };
    }
}
