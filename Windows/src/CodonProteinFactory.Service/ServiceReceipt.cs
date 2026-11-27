using CodonProteinFactory.Domain;

namespace CodonProteinFactory.Service;

public enum ReceiptCode
{
    Verified, Unsuccessful, InvalidSequenceField, InvalidDna, Rejected, NotSubmitted,
    UnexpectedHttpStatus, OversizedResponse, InvalidJson, NonObjectJson, MissingSuccess,
    JsonDepthLimit, JsonNodeLimit, TimedOut, TransportFailure, CancelledAfterDispatch
}

public sealed record ServiceReceipt(ReceiptCode Code, RequestEffect Effect, int? HttpStatus = null,
    VerifiedDna? Result = null, byte[]? Body = null, string? Detail = null)
{
    public RecordStatus RecordStatus => Effect == RequestEffect.Unknown ? RecordStatus.Unknown
        : Result is not null ? RecordStatus.Completed : RecordStatus.Failed;

    public AttemptStatus AttemptStatus => Effect == RequestEffect.Unknown ? AttemptStatus.Unknown
        : Result is not null ? AttemptStatus.Completed : AttemptStatus.Failed;

    public bool ShouldStop => Effect is RequestEffect.Unknown or RequestEffect.NotSubmitted ||
        (Effect == RequestEffect.Rejected && HttpStatus is 401 or 403 or 429);
}

public interface ISubmissionService
{
    Task<ServiceReceipt> SubmitAsync(ServiceRequest request, CancellationToken cancellationToken = default);
}
