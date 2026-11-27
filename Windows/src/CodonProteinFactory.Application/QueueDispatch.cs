using System.Text;
using System.Text.Json;
using CodonProteinFactory.Domain;
using CodonProteinFactory.Persistence;
using CodonProteinFactory.Service;

namespace CodonProteinFactory.Application;

public sealed partial class QueueCoordinator
{
    private void Schedule(BatchSnapshot snapshot)
    {
        int index = queued.FindIndex(item => item.Batch.CreatedAt > snapshot.Batch.CreatedAt);
        queued.Insert(index < 0 ? queued.Count : index, snapshot);
    }

    private void Pump()
    {
        if (inFlight is not null || failure is not null) return;
        if (active is { } running && (running.Batch.StopRequested || NextRecord(running.Batch) < 0)) Finish(running);
        if (closing || (active is null && queued.Count == 0)) return;
        if (lastReceipt is { } receipt && interval - clock.GetElapsedTime(receipt) is { } remaining && remaining > TimeSpan.Zero)
        {
            wakeTimer ??= clock.CreateTimer(_ => commands.Writer.TryWrite(ClearTimer), null, remaining, Timeout.InfiniteTimeSpan);
            return;
        }
        ClearTimer();
        if (active is null)
        {
            var next = queued[0];
            queued.RemoveAt(0);
            active = Storage(() => store.Update(next, next.Batch with { Status = BatchStatus.Running, UpdatedAt = clock.GetUtcNow() }));
            NotifyChanged();
        }
        var snapshot = active;
        int index = NextRecord(snapshot.Batch);
        if (index < 0) { Finish(snapshot); commands.Writer.TryWrite(static () => { }); return; }
        var record = snapshot.Batch.Records[index];
        int attemptNumber = (record.Attempts.LastOrDefault()?.Number ?? 0) + 1;
        if (ExceedsAuditBudget(snapshot.Batch) || record.Attempts.Count >= DomainLimits.MaxAttempts || attemptNumber > DomainLimits.MaxAttempts)
        {
            var message = attemptNumber > DomainLimits.MaxAttempts || record.Attempts.Count >= DomainLimits.MaxAttempts
                ? "attempt_limit_reached" : "audit_budget_reached";
            var stopped = snapshot.Batch with { StopRequested = true, Message = message };
            Finish(snapshot, stopped);
            commands.Writer.TryWrite(static () => { });
            return;
        }
        var request = new ServiceRequest(record, snapshot.Batch.Parameters);
        var attempt = new RequestAttempt(Guid.NewGuid(), attemptNumber, clock.GetUtcNow(), request.PayloadSha256);
        var records = snapshot.Batch.Records.ToArray();
        records[index] = record with { Status = RecordStatus.Running, Attempts = [.. record.Attempts, attempt] };
        active = Storage(() => store.Update(snapshot, snapshot.Batch with { Records = records, UpdatedAt = attempt.StartedAt }));
        inFlight = new CancellationTokenSource();
        long started = clock.GetTimestamp();
        _ = ReceiveAsync(request, inFlight.Token, index, record.Status, attempt, started);
        NotifyChanged();
    }

    private async Task ReceiveAsync(ServiceRequest request, CancellationToken token, int index, RecordStatus prior,
        RequestAttempt attempt, long started)
    {
        ServiceReceipt receipt;
        try { receipt = await service.SubmitAsync(request, token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            receipt = new ServiceReceipt(ReceiptCode.CancelledAfterDispatch, RequestEffect.Unknown);
        }
        catch (Exception)
        {
            receipt = new ServiceReceipt(ReceiptCode.TransportFailure, RequestEffect.Unknown);
        }
        long received = clock.GetTimestamp();
        commands.Writer.TryWrite(() => CompleteAttempt(receipt, index, prior, attempt, started, received));
    }

    private void CompleteAttempt(ServiceReceipt receipt, int index, RecordStatus prior, RequestAttempt attempt, long started, long received)
    {
        inFlight?.Dispose();
        inFlight = null;
        if (failure is not null) return;
        var snapshot = active ?? throw new InvalidOperationException("A receipt arrived without an active batch.");
        var batch = snapshot.Batch;
        var records = batch.Records.ToArray();
        var record = records[index];
        lastReceipt = received;
        DateTimeOffset now = clock.GetUtcNow();
        string? error = receipt.Code == ReceiptCode.Verified ? null : receipt.Detail ?? receipt.Code.ToString();
        attempt = attempt with
        {
            FinishedAt = now, Status = receipt.AttemptStatus, Effect = receipt.Effect, HttpStatus = receipt.HttpStatus,
            ElapsedMilliseconds = (long)clock.GetElapsedTime(started, received).TotalMilliseconds,
            Error = error, ResponseLength = receipt.Body?.Length
        };
        bool remainsUnknown = prior == RecordStatus.Unknown && receipt.Effect == RequestEffect.NotSubmitted;
        records[index] = record with
        {
            Status = remainsUnknown ? RecordStatus.Unknown : receipt.RecordStatus,
            Error = remainsUnknown ? record.Error : error, Dna = receipt.Result?.Dna,
            DnaSha256 = receipt.Result?.Sha256, Checks = receipt.Result?.Checks,
            Attempts = [.. record.Attempts.Take(record.Attempts.Count - 1), attempt]
        };
        active = Storage(() => store.Update(snapshot, batch with
        {
            Records = records, UpdatedAt = now, StopRequested = batch.StopRequested || receipt.ShouldStop,
            Message = batch.StopRequested ? batch.Message : receipt.ShouldStop ? "service_paused_queue" : batch.Message
        }, new AttemptBody(record.Id, attempt.Id, receipt.Body)));
        if (receipt.ShouldStop && !closing) StopQueued("service_paused_queue");
        NotifyChanged();
    }

    private void Finish(BatchSnapshot snapshot, Batch? final = null)
    {
        var batch = final ?? snapshot.Batch;
        var status = BatchSummary.Count(batch.Records).StatusAfterExecution()
            ?? throw new InvalidOperationException("A batch with an in-flight record cannot finish.");
        Storage(() => store.Update(snapshot, batch with { Status = status, UpdatedAt = clock.GetUtcNow() }));
        active = null;
        NotifyChanged();
    }

    private void StopQueued(string reason)
    {
        foreach (var snapshot in queued) MarkStopped(snapshot, reason);
        queued.Clear();
        NotifyChanged();
    }

    private void MarkStopped(BatchSnapshot snapshot, string reason) => Storage(() => store.Update(snapshot, snapshot.Batch with
    {
        Status = BatchStatus.Stopped, StopRequested = true, Message = reason, UpdatedAt = clock.GetUtcNow()
    }));

    private void ClearTimer()
    {
        wakeTimer?.Dispose();
        wakeTimer = null;
    }

    private static int NextRecord(Batch batch)
    {
        for (int i = 0; i < batch.Records.Count; i++)
            if (batch.Records[i].Status is RecordStatus.Pending or RecordStatus.Unknown) return i;
        return -1;
    }

    private static bool ExceedsAuditBudget(Batch batch)
    {
        long size = Encoding.UTF8.GetByteCount(batch.Name) + Encoding.UTF8.GetByteCount(batch.RequestId) + 512;
        foreach (var record in batch.Records)
        {
            size += Encoding.UTF8.GetByteCount(record.Name) + record.OriginalSequence.Value.Length + record.Sequence.Value.Length +
                (record.Dna?.Length ?? 0) + 256;
            foreach (var attempt in record.Attempts)
            {
                size += JsonSerializer.SerializeToUtf8Bytes(attempt).Length;
                if (attempt.ResponseLength is { } length) size += 4L * ((length + 2) / 3);
                if (size > MaxAuditBytes) return true;
            }
        }
        return size > MaxAuditBytes;
    }
}
