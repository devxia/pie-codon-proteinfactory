using System.Net;
using System.Net.Http.Headers;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Service;

public sealed class ProteinServiceClient : ISubmissionService, IDisposable
{
    public const int MaxResponseBytes = 1_048_576;
    public static TimeSpan DefaultTimeout { get; } = TimeSpan.FromSeconds(120);
    private static readonly ProductInfoHeaderValue ClientProduct = new(
        "CodonProteinFactory", typeof(ProteinServiceClient).Assembly.GetName().Version!.ToString(3));
    private readonly HttpClient client;
    private readonly TimeSpan timeout;

    public ProteinServiceClient() : this(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        Credentials = null,
        DefaultProxyCredentials = null,
        MaxConnectionsPerServer = 1,
        AutomaticDecompression = DecompressionMethods.All
    }, DefaultTimeout) { }

    public ProteinServiceClient(HttpMessageHandler transport, TimeSpan timeout)
    {
        ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(timeout, TimeSpan.Zero);
        this.timeout = timeout;
        client = new HttpClient(transport) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<ServiceReceipt> SubmitAsync(ServiceRequest request, CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
            return new ServiceReceipt(ReceiptCode.NotSubmitted, RequestEffect.NotSubmitted);

        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        var token = timeoutSource.Token;
        using var message = new HttpRequestMessage(HttpMethod.Post, Batch.ServiceEndpoint) { Content = request.CreateContent() };
        // The service redirects requests that arrive without a client identity.
        message.Headers.UserAgent.Add(ClientProduct);
        message.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        message.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        message.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        int? status = null;
        try
        {
            using var response = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            status = (int)response.StatusCode;
            byte[]? raw = await ReadBoundedAsync(response.Content, token).ConfigureAwait(false);
            return ResponseClassifier.Classify(status.Value, raw, request);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new ServiceReceipt(ReceiptCode.CancelledAfterDispatch, RequestEffect.Unknown, status);
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested)
        {
            return new ServiceReceipt(ReceiptCode.TimedOut, RequestEffect.Unknown, status);
        }
        catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException)
        {
            return new ServiceReceipt(ReceiptCode.TransportFailure, RequestEffect.Unknown, status);
        }
    }

    private static async Task<byte[]?> ReadBoundedAsync(HttpContent content, CancellationToken token)
    {
        if (content.Headers.ContentLength > MaxResponseBytes) return null;
        await using var input = await content.ReadAsStreamAsync(token).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            int count = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, MaxResponseBytes + 1 - output.Length)), token)
                .ConfigureAwait(false);
            if (count == 0) return output.ToArray();
            if (output.Length + count > MaxResponseBytes) return null;
            output.Write(buffer, 0, count);
        }
    }

    public void Dispose() => client.Dispose();
}
