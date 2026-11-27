using System.Threading.Channels;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.Service;

namespace CodonProteinFactory.Application;

public sealed partial class QueueCoordinator : IAsyncDisposable
{
    public const int MaxScheduledBatches = 10;
    public const int MaxAuditBytes = 8 * 1024 * 1024;
    private readonly IWorkspaceStore store;
    private readonly ISubmissionService service;
    private readonly TimeProvider clock;
    private readonly TimeSpan interval;
    private readonly Channel<Action> commands = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Task worker;
    private readonly List<BatchSnapshot> queued = [];
    private readonly List<TaskCompletionSource> idle = [];
    private readonly TaskCompletionSource shutdown = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private BatchSnapshot? active;
    private CancellationTokenSource? inFlight;
    private ITimer? wakeTimer;
    private long? lastReceipt;
    private bool closing;
    private Exception? failure;
    private int shutdownRequested;

    public QueueCoordinator(IWorkspaceStore store, ISubmissionService service, TimeProvider? clock = null, TimeSpan? interval = null)
    {
        this.store = store;
        this.service = service;
        this.clock = clock ?? TimeProvider.System;
        this.interval = interval ?? TimeSpan.FromMilliseconds(500);
        ArgumentOutOfRangeException.ThrowIfLessThan(this.interval, TimeSpan.Zero);
        worker = Task.Run(RunAsync);
    }

    public event Action? Changed;
    public event Action<Exception>? Faulted;

    public Task SaveDraftAsync(Batch draft) => Enqueue(() =>
    {
        CheckOpen();
        ValidateDraft(draft);
        var existing = Storage(() => store.Load(draft.Id));
        if (existing is null) Storage(() => store.Insert(draft));
        else if (!SameDraft(existing.Batch, draft)) throw Duplicate();
    });

    public Task SubmitAsync(Batch confirmed) => Enqueue(() =>
    {
        CheckCapacity();
        ValidateDraft(confirmed);
        var saved = Storage(() => store.Load(confirmed.Id));
        if (saved is not null)
        {
            if (!SameDraft(saved.Batch, confirmed)) throw Duplicate();
            ValidateDraft(saved.Batch);
        }
        DateTimeOffset now = clock.GetUtcNow();
        var queuedBatch = confirmed with { Status = BatchStatus.Queued, AuthorizedAt = now, UpdatedAt = now };
        var snapshot = saved is null ? Storage(() => store.Insert(queuedBatch)) : Storage(() => store.Update(saved, queuedBatch));
        Schedule(snapshot);
    });

    public Task RetryAsync(Guid batchId, ConfirmedUnknownRetry? confirmation = null) => Enqueue(() =>
    {
        CheckCapacity();
        var snapshot = Storage(() => store.Load(batchId)) ?? throw new QueueException(QueueErrorCode.MissingBatch, "The batch was not found.");
        if (confirmation is not null && (confirmation.BatchId != batchId || !confirmation.Matches(snapshot.Batch)))
            throw new QueueException(QueueErrorCode.StaleConfirmation, "The unknown attempts changed. Review and confirm again.");
        var ids = RetryPolicy.EligibleRecords(snapshot.Batch, confirmation is not null).ToHashSet();
        var batch = snapshot.Batch with
        {
            Status = BatchStatus.Queued, UpdatedAt = clock.GetUtcNow(), StopRequested = false, Message = string.Empty,
            Records = snapshot.Batch.Records.Select(record => ids.Contains(record.Id) ? record with
            {
                Status = record.Status == RecordStatus.Unknown ? RecordStatus.Unknown : RecordStatus.Pending,
                Error = record.Status == RecordStatus.Unknown ? record.Error : null, Dna = null, DnaSha256 = null, Checks = null
            } : record).ToArray()
        };
        Schedule(Storage(() => store.Update(snapshot, batch)));
    });

    public Task StopAsync(Guid id) => Enqueue(() =>
    {
        CheckOpen();
        if (active?.Batch.Id == id)
        {
            var snapshot = active;
            active = Storage(() => store.Update(snapshot, snapshot.Batch with
            { StopRequested = true, UpdatedAt = clock.GetUtcNow(), Message = "stopped_by_user" }));
            inFlight?.Cancel();
        }
        else if (queued.FindIndex(entry => entry.Batch.Id == id) is int index && index >= 0)
        {
            MarkStopped(queued[index], "stopped_by_user");
            queued.RemoveAt(index);
        }
    });

    public Task WaitForIdleAsync()
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!commands.Writer.TryWrite(() => idle.Add(completion))) return shutdown.Task;
        return completion.Task;
    }

    public async Task ShutdownAsync()
    {
        if (Interlocked.Exchange(ref shutdownRequested, 1) == 0)
            commands.Writer.TryWrite(BeginShutdown);
        try { await shutdown.Task.ConfigureAwait(false); }
        finally { await worker.ConfigureAwait(false); }
    }

    public async ValueTask DisposeAsync() => await ShutdownAsync().ConfigureAwait(false);

    private void BeginShutdown()
    {
        closing = true;
        try
        {
            StopQueued("application_exiting");
            if (active is { } snapshot && !snapshot.Batch.StopRequested)
                active = Storage(() => store.Update(snapshot, snapshot.Batch with
                { StopRequested = true, UpdatedAt = clock.GetUtcNow(), Message = "application_exiting" }));
        }
        finally { inFlight?.Cancel(); }
    }

    private Task Enqueue(Action action)
    {
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!commands.Writer.TryWrite(() =>
        {
            try { action(); result.TrySetResult(); NotifyChanged(); }
            catch (Exception error) { result.TrySetException(error); }
        })) result.TrySetException(new QueueException(QueueErrorCode.Closed, "The queue is closed."));
        return result.Task;
    }

    private async Task RunAsync()
    {
        await foreach (var command in commands.Reader.ReadAllAsync().ConfigureAwait(false))
        {
            try
            {
                command();
                Pump();
            }
            catch (Exception error) { Fail(error); }
            if (active is null && queued.Count == 0 && inFlight is null)
            {
                foreach (var completion in idle)
                    if (failure is null) completion.TrySetResult(); else completion.TrySetException(failure);
                idle.Clear();
                if (closing)
                {
                    wakeTimer?.Dispose();
                    commands.Writer.TryComplete();
                    if (failure is null) shutdown.TrySetResult(); else shutdown.TrySetException(failure);
                }
            }
        }
    }

    private T Storage<T>(Func<T> operation)
    {
        try { return operation(); }
        catch (Exception error)
        {
            Fail(error);
            throw new QueueException(QueueErrorCode.StorageFailure, "The queue stopped because the workspace could not be updated.", error);
        }
    }

    private void Fail(Exception error)
    {
        if (failure is not null) return;
        failure = error;
        closing = true;
        active = null;
        queued.Clear();
        inFlight?.Cancel();
        try { Faulted?.Invoke(error); }
        catch { /* A UI observer cannot prevent queue recovery. */ }
    }

    private void NotifyChanged()
    {
        try { Changed?.Invoke(); }
        catch { /* State is durable before notification. */ }
    }

    private void CheckOpen()
    {
        if (failure is not null) throw new QueueException(QueueErrorCode.StorageFailure, "The workspace must be reopened.", failure);
        if (closing || Volatile.Read(ref shutdownRequested) != 0) throw new QueueException(QueueErrorCode.Closed, "The queue is closed.");
    }

    private void CheckCapacity()
    {
        CheckOpen();
        if (queued.Count + (active is null ? 0 : 1) >= MaxScheduledBatches)
            throw new QueueException(QueueErrorCode.Capacity, "The queue already has 10 scheduled batches.");
    }

    private static void ValidateDraft(Batch draft)
    {
        if (draft.Status != BatchStatus.Prepared || draft.AuthorizedAt is not null || draft.StopRequested ||
            draft.Records.Count is < 1 or > DomainLimits.MaxRecords ||
            draft.Records.Any(record => record.Status != RecordStatus.Pending || record.Attempts.Count != 0 || record.Dna is not null))
            throw new QueueException(QueueErrorCode.InvalidDraft, "The preview is not an unsubmitted draft.");
        PreviewIntegrity.Verify(draft);
    }

    private static bool SameDraft(Batch saved, Batch supplied) => saved.Status == BatchStatus.Prepared && saved.AuthorizedAt is null &&
        saved.Id == supplied.Id && saved.RequestId == supplied.RequestId && saved.Name == supplied.Name && saved.Parameters == supplied.Parameters &&
        saved.Fingerprint == supplied.Fingerprint && saved.Endpoint.OriginalString == supplied.Endpoint.OriginalString &&
        saved.Records.Select(record => (record.Id, record.InputSha256, record.Status, record.Attempts.Count))
            .SequenceEqual(supplied.Records.Select(record => (record.Id, record.InputSha256, record.Status, record.Attempts.Count)));

    private static QueueException Duplicate() => new(QueueErrorCode.Duplicate, "This draft was already submitted or has changed.");
}
