namespace CodonProteinFactory.Domain;

public enum DomainErrorCode
{
    EmptySequence, InvalidResidue, MisplacedStop, SequenceTooLong, StopExceedsLimit,
    InvalidBatchName, InvalidRequestId, InvalidRecordName, TextTooLarge, RecordCount, BatchTooLong,
    MotifsTooLong, InvalidMotif, EmptyDna, InvalidBase, IncorrectDnaLength, TranslationMismatch,
    UnexpectedStop, MissingTerminalStop, ForbiddenMotif, MissingDna, DnaHashMismatch,
    EndpointMismatch, FingerprintMismatch, RecordLayoutMismatch, InputHashMismatch,
    InvalidBatchState, RecordRunning, UnknownRequiresConfirmation, NoPendingRecords, AttemptLimit
}

public sealed class DomainException(DomainErrorCode code, string message, int? position = null, int? sourceRow = null,
    Exception? innerException = null) : Exception(message, innerException)
{
    public DomainErrorCode Code { get; } = code;
    public int? Position { get; } = position;
    public int? SourceRow { get; } = sourceRow;
}
