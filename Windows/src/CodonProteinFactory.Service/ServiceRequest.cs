using System.Buffers;
using System.Text.Encodings.Web;
using System.Text.Json;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Service;

public sealed class ServiceRequest
{
    private readonly byte[] body;

    public ServiceRequest(SequenceRecord record, OptimizationParameters parameters)
    {
        Record = record;
        Parameters = parameters;
        var output = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(output, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteString("fileName", record.Name);
            writer.WriteString("ignoreCodonQueue", parameters.Avoid.WireValue);
            writer.WriteString("jumpName", "pep");
            writer.WriteString("sequence", record.Sequence.Value);
            writer.WriteString("speciesName", parameters.Species.WireValue());
            writer.WriteEndObject();
        }
        // Foundation escapes forward slashes in its default compact JSON encoding.
        var payload = System.Text.Encoding.UTF8.GetString(output.WrittenSpan).Replace("/", "\\/", StringComparison.Ordinal);
        body = System.Text.Encoding.UTF8.GetBytes(payload);
        PayloadSha256 = Digests.Sha256(body);
    }

    public SequenceRecord Record { get; }
    public OptimizationParameters Parameters { get; }
    public string PayloadSha256 { get; }
    internal HttpContent CreateContent() => new ByteArrayContent(body);
}
