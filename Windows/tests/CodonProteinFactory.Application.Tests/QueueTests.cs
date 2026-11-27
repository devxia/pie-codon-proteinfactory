using System.Threading.Channels;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.Service;

namespace CodonProteinFactory.Application.Tests;

public sealed class QueueTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "CodonFactoryQueue-" + Guid.NewGuid().ToString("N"));
    private static readonly TimeSpan Deadline = TimeSpan.FromSeconds(8);

    [Fact]
    public async Task AuthorizesSavedDraftOnceAndPersistsEachAttemptBeforeSending()
    {
        var store = new WorkspaceStore(directory);
        var service = new ControlledService();
        await using var queue = new QueueCoordinator(store, service, interval: TimeSpan.Zero);
        var batch = Draft(2);
        await queue.SaveDraftAsync(batch);
        await queue.SaveDraftAsync(batch);
        Assert.Equal(BatchStatus.Prepared, store.Load(batch.Id)!.Batch.Status);
        Assert.Equal(0, service.Sent);
        await queue.SubmitAsync(batch);
        var first = await service.Next();
        var persisted = store.Load(batch.Id)!.Batch;
        Assert.Equal(AttemptStatus.Dispatching, Assert.Single(persisted.Records[0].Attempts).Status);
        Assert.NotNull(persisted.AuthorizedAt);
        Assert.Equal(first.Request.PayloadSha256, persisted.Records[0].Attempts[0].PayloadSha256);
        var repeated = await Task.WhenAll(Enumerable.Range(0, 16).Select(async _ =>
            await Assert.ThrowsAsync<QueueException>(() => queue.SubmitAsync(batch))));
        Assert.All(repeated, error => Assert.Equal(QueueErrorCode.Duplicate, error.Code));
        Assert.Equal(1, service.Sent);
        first.Finish();
        var second = await service.Next();
        Assert.Equal(2, second.Request.Record.Position);
        second.Finish();
        await queue.WaitForIdleAsync().WaitAsync(Deadline);
        Assert.Equal(BatchStatus.Completed, store.Load(batch.Id)!.Batch.Status);
        Assert.Equal(2, service.Sent);
    }

    [Fact]
    public async Task StopBeforeDispatchLeavesNoAttemptAndStopAfterDispatchRequiresConfirmation()
    {
        var store = new WorkspaceStore(directory);
        var service = new ControlledService();
        await using var queue = new QueueCoordinator(store, service, interval: TimeSpan.Zero);
        var active = Draft(2);
        var queued = Draft(1);
        await queue.SubmitAsync(active);
        await service.Next();
        await queue.SubmitAsync(queued);
        await queue.StopAsync(queued.Id);
        Assert.Empty(store.Load(queued.Id)!.Batch.Records[0].Attempts);
        await queue.StopAsync(active.Id);
        await queue.WaitForIdleAsync().WaitAsync(Deadline);
        var unknown = store.Load(active.Id)!.Batch;
        Assert.Equal(BatchStatus.Unknown, unknown.Status);
        Assert.Equal(RecordStatus.Pending, unknown.Records[1].Status);
        Assert.Equal(RequestEffect.Unknown, Assert.Single(unknown.Records[0].Attempts).Effect);
        var ordinary = await Assert.ThrowsAsync<DomainException>(() => queue.RetryAsync(active.Id));
        Assert.Equal(DomainErrorCode.UnknownRequiresConfirmation, ordinary.Code);
        var confirmation = new ConfirmedUnknownRetry(unknown);
        await queue.RetryAsync(active.Id, confirmation);
        var retried = await service.Next();
        Assert.Equal(unknown.Records[0].Id, retried.Request.Record.Id);
        await queue.StopAsync(active.Id);
        await queue.WaitForIdleAsync().WaitAsync(Deadline);
        var stale = await Assert.ThrowsAsync<QueueException>(() => queue.RetryAsync(active.Id, confirmation));
        Assert.Equal(QueueErrorCode.StaleConfirmation, stale.Code);
        Assert.Equal(2, store.Load(active.Id)!.Batch.Records[0].Attempts.Count);
    }

    [Fact]
    public async Task ExitCancelsAndDrainsBeforeClosing()
    {
        var store = new WorkspaceStore(directory);
        var service = new ControlledService();
        await using var queue = new QueueCoordinator(store, service, interval: TimeSpan.Zero);
        var active = Draft(1);
        var queued = Draft(1);
        await queue.SubmitAsync(active);
        await service.Next();
        await queue.SubmitAsync(queued);
        await queue.ShutdownAsync().WaitAsync(Deadline);
        Assert.Equal(BatchStatus.Unknown, new WorkspaceStore(directory).Load(active.Id)!.Batch.Status);
        Assert.Equal(BatchStatus.Stopped, store.Load(queued.Id)!.Batch.Status);
        Assert.Empty(store.Load(queued.Id)!.Batch.Records[0].Attempts);
        Assert.Equal(QueueErrorCode.Closed, (await Assert.ThrowsAsync<QueueException>(() => queue.SubmitAsync(Draft(1)))).Code);
    }

    [Fact]
    public async Task FailedResultWriteLeavesNoCompletedDnaAndRecoversInterruptedAttempt()
    {
        var store = new WorkspaceStore(directory);
        var service = new ControlledService();
        var queue = new QueueCoordinator(new FailingReceiptStore(store), service, interval: TimeSpan.Zero);
        var batch = Draft(1);
        await queue.SubmitAsync(batch);
        var pending = await service.Next();
        pending.Finish();
        await Assert.ThrowsAsync<IOException>(() => queue.WaitForIdleAsync().WaitAsync(Deadline));
        await Assert.ThrowsAsync<IOException>(() => queue.ShutdownAsync());
        var before = store.Load(batch.Id)!.Batch;
        Assert.Equal(RecordStatus.Running, before.Records[0].Status);
        Assert.Null(before.Records[0].Dna);
        QueueRecovery.Recover(store, TimeProvider.System);
        var after = store.Load(batch.Id)!.Batch;
        Assert.Equal(BatchStatus.Unknown, after.Status);
        Assert.Equal(AttemptStatus.Unknown, Assert.Single(after.Records[0].Attempts).Status);
        Assert.Null(after.Records[0].Dna);
    }

    [Fact]
    public async Task CapacityIncludesTheActiveBatch()
    {
        var store = new WorkspaceStore(directory);
        var service = new ControlledService();
        await using var queue = new QueueCoordinator(store, service, interval: TimeSpan.Zero);
        await queue.SubmitAsync(Draft(1));
        await service.Next();
        for (int i = 1; i < QueueCoordinator.MaxScheduledBatches; i++) await queue.SubmitAsync(Draft(1));
        var error = await Assert.ThrowsAsync<QueueException>(() => queue.SubmitAsync(Draft(1)));
        Assert.Equal(QueueErrorCode.Capacity, error.Code);
        Assert.Equal(1, service.Sent);
    }

    private static Batch Draft(int count) => BatchPreparation.Prepare("Queue test",
        Enumerable.Range(1, count).Select(i => new SequenceRecordInput($"Record {i}", "A")).ToArray());

    private sealed class ControlledService : ISubmissionService
    {
        private readonly Channel<Pending> calls = Channel.CreateUnbounded<Pending>();
        private int sent;
        public int Sent => Volatile.Read(ref sent);

        public async Task<ServiceReceipt> SubmitAsync(ServiceRequest request, CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref sent);
            var call = new Pending(request);
            await calls.Writer.WriteAsync(call, cancellationToken);
            return await call.Completion.Task.WaitAsync(cancellationToken);
        }

        public Task<Pending> Next() => calls.Reader.ReadAsync().AsTask().WaitAsync(Deadline);
    }

    private sealed record Pending(ServiceRequest Request)
    {
        public TaskCompletionSource<ServiceReceipt> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Finish() => Completion.SetResult(new ServiceReceipt(ReceiptCode.Verified, RequestEffect.Completed, 200,
            DnaValidation.Verify("GCT", Request.Record.Sequence), "success"u8.ToArray()));
    }

    private sealed class FailingReceiptStore(IWorkspaceStore store) : IWorkspaceStore
    {
        public BatchSnapshot Insert(Batch batch) => store.Insert(batch);
        public BatchSnapshot Update(BatchSnapshot snapshot, Batch batch, AttemptBody? body = null) =>
            body is null ? store.Update(snapshot, batch) : throw new IOException("Test disk failure");
        public BatchSnapshot? Load(Guid id) => store.Load(id);
        public IReadOnlyList<BatchHistoryRow> History(HistoryQuery query) => store.History(query);
        public bool Delete(Guid batchId) => store.Delete(batchId);
        public AttemptResponse ReadResponse(Guid recordId, Guid attemptId) => store.ReadResponse(recordId, attemptId);
    }

    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
}
