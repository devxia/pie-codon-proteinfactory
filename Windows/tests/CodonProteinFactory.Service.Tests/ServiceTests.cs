using System.Net;
using System.Text;
using System.Text.Json;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Service.Tests;

public sealed class ServiceTests
{
    [Fact]
    public async Task SendsGoldenRequestAndRetainsOriginalReceipt()
    {
        string directory = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        string expected = File.ReadAllText(Path.Combine(directory, "request-ascii.json")).TrimEnd('\r', '\n');
        using var input = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory, "request-ascii-input.json")));
        var root = input.RootElement;
        var parameters = new OptimizationParameters
        {
            Species = Enum.Parse<Species>(root.GetProperty("species").GetString()!),
            StopPolicy = Enum.Parse<StopPolicy>(root.GetProperty("stopPolicy").GetString()!),
            Avoid = AvoidMotifs.Parse(root.GetProperty("customMotifs").GetString()!,
                root.GetProperty("enzymes").EnumerateArray().Select(e => Enum.Parse<RestrictionEnzyme>(e.GetString()!)))
        };
        var batch = BatchPreparation.Prepare("Contract", [new(root.GetProperty("name").GetString()!, root.GetProperty("sequence").GetString()!)], parameters);
        const string raw = "{ \"success\": 1, \"seq\": \"ATGTAA\" }";
        var transport = new FakeTransport(async (message, token) =>
        {
            Assert.Equal(HttpMethod.Post, message.Method);
            Assert.Equal(Batch.ServiceEndpoint, message.RequestUri);
            Assert.Equal("application/json", message.Content!.Headers.ContentType!.MediaType);
            Assert.Equal("application/json", Assert.Single(message.Headers.Accept).MediaType);
            Assert.True(message.Headers.CacheControl!.NoCache);
            Assert.Equal(expected, await message.Content.ReadAsStringAsync(token));
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(raw) };
        });
        using var client = new ProteinServiceClient(transport, TimeSpan.FromSeconds(1));
        var request = new ServiceRequest(batch.Records[0], parameters);
        var receipt = await client.SubmitAsync(request);
        Assert.Equal(Digests.Sha256(expected), request.PayloadSha256);
        Assert.Equal(ReceiptCode.Verified, receipt.Code);
        Assert.Equal(raw, Encoding.UTF8.GetString(receipt.Body!));
        Assert.Equal(1, transport.Calls);
    }

    [Fact]
    public async Task IdentifiesTheNativeClientSoTheServerReturnsAResult()
    {
        var transport = new FakeTransport((message, _) =>
        {
            string expectedVersion = typeof(ProteinServiceClient).Assembly.GetName().Version!.ToString(3);
            bool identified = message.Headers.UserAgent.Any(value => value.Product is { } product &&
                product.Name == "CodonProteinFactory" && product.Version == expectedVersion);
            var response = identified
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":\"1\",\"seq\":\"GCT\"}") }
                : new HttpResponseMessage(HttpStatusCode.Found) { Content = new StringContent("<html>302 Found</html>") };
            return Task.FromResult(response);
        });
        using var client = new ProteinServiceClient(transport, TimeSpan.FromSeconds(1));

        var receipt = await client.SubmitAsync(Request());

        Assert.Equal(ReceiptCode.Verified, receipt.Code);
        Assert.Equal("GCT", receipt.Result?.Dna);
        Assert.Equal(1, transport.Calls);
    }

    [Theory]
    [InlineData("{\"success\":\"1\",\"seq\":\"GCT\"}", ReceiptCode.Verified)]
    [InlineData("{\"success\":1e+0,\"seq\":\"GCT\"}", ReceiptCode.Verified)]
    [InlineData("{\"success\":-1,\"seq\":\"GCT\"}", ReceiptCode.Unsuccessful)]
    [InlineData("{\"success\":1e400,\"seq\":\"GCT\"}", ReceiptCode.Unsuccessful)]
    [InlineData("{\"success\":null}", ReceiptCode.Unsuccessful)]
    [InlineData("{\"seq\":\"GCT\"}", ReceiptCode.MissingSuccess)]
    [InlineData("{\"success\":1,\"seq\":null}", ReceiptCode.InvalidSequenceField)]
    [InlineData("{\"success\":1,\"seq\":\"ATG\"}", ReceiptCode.InvalidDna)]
    [InlineData("{\"success\":01,\"seq\":\"GCT\"}", ReceiptCode.InvalidJson)]
    [InlineData("{\"success\":+1}", ReceiptCode.InvalidJson)]
    [InlineData("{\"success\":1e+}", ReceiptCode.InvalidJson)]
    [InlineData("{\"success\":1}{}", ReceiptCode.InvalidJson)]
    [InlineData("[1]", ReceiptCode.NonObjectJson)]
    public void ClassifiesStrictJsonAndVerification(string body, ReceiptCode expected) =>
        Assert.Equal(expected, ResponseClassifier.Classify(200, Encoding.UTF8.GetBytes(body), Request()).Code);

    [Fact]
    public void EnforcesJsonDepthAndNodeBudgets()
    {
        var request = Request();
        byte[] badUtf8 = [123, 34, 120, 34, 58, 34, 255, 34, 125];
        Assert.Equal(ReceiptCode.InvalidJson, ResponseClassifier.Classify(200, badUtf8, request).Code);
        byte[] nested = Encoding.UTF8.GetBytes(new string('[', 33) + new string(']', 33));
        Assert.Equal(ReceiptCode.JsonDepthLimit, ResponseClassifier.Classify(200, nested, request).Code);
        byte[] many = Encoding.UTF8.GetBytes("[" + string.Join(',', Enumerable.Repeat("0", 250_000)) + "]");
        Assert.Equal(ReceiptCode.JsonNodeLimit, ResponseClassifier.Classify(200, many, request).Code);
    }

    [Theory]
    [InlineData(302, ReceiptCode.UnexpectedHttpStatus, true)]
    [InlineData(400, ReceiptCode.Rejected, false)]
    [InlineData(401, ReceiptCode.Rejected, true)]
    [InlineData(408, ReceiptCode.UnexpectedHttpStatus, true)]
    [InlineData(429, ReceiptCode.Rejected, true)]
    [InlineData(500, ReceiptCode.UnexpectedHttpStatus, true)]
    public void ClassifiesHttpStatusWithoutTreatingUncertaintyAsFailure(int status, ReceiptCode code, bool stop)
    {
        var receipt = ResponseClassifier.Classify(status, [], Request());
        Assert.Equal(code, receipt.Code);
        Assert.Equal(stop, receipt.ShouldStop);
    }

    [Fact]
    public async Task ReadsAtMostOneBytePastStreamLimit()
    {
        var stream = new CountingStream();
        using var client = new ProteinServiceClient(new FakeTransport((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(stream) })), TimeSpan.FromSeconds(2));
        var receipt = await client.SubmitAsync(Request());
        Assert.Equal(ReceiptCode.OversizedResponse, receipt.Code);
        Assert.Null(receipt.Body);
        Assert.Equal(ProteinServiceClient.MaxResponseBytes + 1, stream.BytesRead);
    }

    [Fact]
    public async Task DistinguishesCancellationBeforeDispatchFromTimeoutAfterDispatch()
    {
        var transport = new FakeTransport(async (_, token) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException();
        });
        using var client = new ProteinServiceClient(transport, TimeSpan.FromMilliseconds(30));
        Assert.Equal(ReceiptCode.NotSubmitted, (await client.SubmitAsync(Request(), new CancellationToken(true))).Code);
        Assert.Equal(0, transport.Calls);
        Assert.Equal(ReceiptCode.TimedOut, (await client.SubmitAsync(Request())).Code);
        Assert.Equal(1, transport.Calls);
    }

    private static ServiceRequest Request()
    {
        var batch = BatchPreparation.Prepare("Contract", [new("Sample", "A")]);
        return new ServiceRequest(batch.Records[0], batch.Parameters);
    }

    private sealed class FakeTransport(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            return send(request, cancellationToken);
        }
    }

    private sealed class CountingStream : Stream
    {
        public int BytesRead { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => BytesRead; set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            buffer.Span.Fill((byte)'x');
            BytesRead += buffer.Length;
            return ValueTask.FromResult(buffer.Length);
        }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
    }
}
