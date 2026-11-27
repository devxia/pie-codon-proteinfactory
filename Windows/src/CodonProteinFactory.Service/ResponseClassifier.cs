using System.Text;
using System.Text.Json;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Service;

public static class ResponseClassifier
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private const int MaxDepth = 32;
    private const int MaxNodes = 250_000;

    public static ServiceReceipt Classify(int httpStatus, byte[]? body, ServiceRequest request)
    {
        ServiceReceipt Receipt(ReceiptCode code, RequestEffect effect, VerifiedDna? result = null, string? detail = null) =>
            new(code, effect, httpStatus, result, body, detail);

        if (body is null || body.Length > ProteinServiceClient.MaxResponseBytes)
            return new ServiceReceipt(ReceiptCode.OversizedResponse, RequestEffect.Unknown, httpStatus);
        if (httpStatus is >= 400 and < 500 and not 408) return Receipt(ReceiptCode.Rejected, RequestEffect.Rejected);
        if (httpStatus is < 200 or >= 300) return Receipt(ReceiptCode.UnexpectedHttpStatus, RequestEffect.Unknown);

        try
        {
            StrictUtf8.GetCharCount(body);
            var reader = new Utf8JsonReader(body, new JsonReaderOptions { MaxDepth = MaxDepth + 1 });
            int nodes = 0;
            while (reader.Read())
            {
                if (reader.TokenType is JsonTokenType.PropertyName or JsonTokenType.String) _ = reader.GetString();
                if (reader.TokenType is JsonTokenType.EndArray or JsonTokenType.EndObject or JsonTokenType.PropertyName) continue;
                if (reader.CurrentDepth >= MaxDepth) return Receipt(ReceiptCode.JsonDepthLimit, RequestEffect.Unknown);
                if (++nodes > MaxNodes) return Receipt(ReceiptCode.JsonNodeLimit, RequestEffect.Unknown);
            }
            using var parsed = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = MaxDepth });
            var root = parsed.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return Receipt(ReceiptCode.NonObjectJson, RequestEffect.Unknown);
            if (!root.TryGetProperty("success", out var success)) return Receipt(ReceiptCode.MissingSuccess, RequestEffect.Unknown);
            bool successful = success.ValueKind switch
            {
                JsonValueKind.String => success.GetString() == "1",
                JsonValueKind.Number => success.TryGetDouble(out double value) && value == 1,
                _ => false
            };
            if (!successful) return Receipt(ReceiptCode.Unsuccessful, RequestEffect.Completed);
            if (!root.TryGetProperty("seq", out var sequence) || sequence.ValueKind != JsonValueKind.String)
                return Receipt(ReceiptCode.InvalidSequenceField, RequestEffect.Completed);

            string dna = sequence.GetString()!;
            var parameters = request.Parameters;
            var protein = request.Record.Sequence;
            if (parameters.StartPolicy.PrefixLength(protein) > 0) dna = "ATG" + dna;
            try
            {
                return Receipt(ReceiptCode.Verified, RequestEffect.Completed,
                    DnaValidation.Verify(dna, protein, parameters.Avoid, parameters.StartPolicy));
            }
            catch (DomainException error) { return Receipt(ReceiptCode.InvalidDna, RequestEffect.Completed, detail: error.Message); }
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException or InvalidOperationException)
        {
            return Receipt(ReceiptCode.InvalidJson, RequestEffect.Unknown);
        }
    }
}
