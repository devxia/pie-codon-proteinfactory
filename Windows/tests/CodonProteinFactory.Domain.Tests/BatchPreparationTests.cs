namespace CodonProteinFactory.Domain.Tests;

public sealed class BatchPreparationTests
{
    [Fact]
    public void ValidatesUtf16NameLimitBeforeTrimmingAndPreservesSourceRow()
    {
        string limit = string.Concat(Enumerable.Repeat("😀", 150));
        Assert.Equal(limit, BatchPreparation.ValidatedRecordName(limit));
        Assert.Null(BatchPreparation.ValidatedRecordName(limit + " "));
        Assert.Null(BatchPreparation.ValidatedRecordName("x\ty"));
        var invalid = Assert.Throws<DomainException>(() => BatchPreparation.Prepare("Draft", [new(" ", "Q", 7)]));
        Assert.Equal(DomainErrorCode.InvalidRecordName, invalid.Code);
        Assert.Equal(7, invalid.SourceRow);
    }

    [Fact]
    public void IncludesOriginalStopsInBatchLimitAndKeepsSubmittedLengthSeparate()
    {
        var inputs = Enumerable.Repeat(new SequenceRecordInput("Synthetic", new string('A', 1000)), 200).ToArray();
        var batch = BatchPreparation.Prepare("Draft", inputs, new OptimizationParameters { StopPolicy = StopPolicy.Add });
        Assert.Equal(200_000, batch.OriginalSequenceLength);
        Assert.Equal(200_200, batch.SubmittedSequenceLength);
        Assert.Equal(200, batch.Records.Count);
        Assert.Equal(DomainErrorCode.RecordCount,
            Assert.Throws<DomainException>(() => BatchPreparation.Prepare("Draft", [.. inputs, inputs[0]])).Code);
        inputs[^1] = inputs[^1] with { Sequence = inputs[^1].Sequence + "*" };
        Assert.Equal(DomainErrorCode.BatchTooLong, Assert.Throws<DomainException>(() => BatchPreparation.Prepare("Draft", inputs)).Code);
    }

    [Fact]
    public void NormalizesAndDeduplicatesMotifsInWireOrder()
    {
        var motifs = AvoidMotifs.Parse("gaattc，GGT(A/T)ACC", [RestrictionEnzyme.EcoRI, RestrictionEnzyme.BamHI]);
        Assert.Equal("GAATTC,GGTAACC,GGTTACC,GGATCC", motifs.WireValue);
        Assert.Equal(motifs, AvoidMotifs.FromWireValue(motifs.WireValue));
        Assert.Equal(2_000, AvoidMotifs.Parse(new string('A', 2_000)).WireValue.Length);
        Assert.Equal(DomainErrorCode.MotifsTooLong, Assert.Throws<DomainException>(() => AvoidMotifs.Parse(new string('A', 2_001))).Code);
        Assert.Equal(DomainErrorCode.InvalidMotif, Assert.Throws<DomainException>(() => AvoidMotifs.FromWireValue("A,A")).Code);
    }

    [Fact]
    public void DetectsChangedDraftsAndDuplicateRecordIdentities()
    {
        var batch = BatchPreparation.Prepare("Draft", [new("One", "A"), new("Two", "M")]);
        PreviewIntegrity.Verify(batch);
        var edited = batch with { Name = "Edited" };
        Assert.Equal(DomainErrorCode.FingerprintMismatch, Assert.Throws<DomainException>(() => PreviewIntegrity.Verify(edited)).Code);
        var duplicate = batch with { Records = [batch.Records[0], batch.Records[1] with { Id = batch.Records[0].Id }] };
        Assert.Equal(DomainErrorCode.RecordLayoutMismatch, Assert.Throws<DomainException>(() => PreviewIntegrity.Verify(duplicate)).Code);
    }

    [Fact]
    public void RetryRequiresUnknownConfirmationAndHonorsAttemptLimit()
    {
        var batch = BatchPreparation.Prepare("Draft", [new("One", "A")]);
        var record = batch.Records[0] with { Status = RecordStatus.Unknown };
        batch = batch with { Status = BatchStatus.Unknown, Records = [record] };
        Assert.Equal(DomainErrorCode.UnknownRequiresConfirmation, Assert.Throws<DomainException>(() => RetryPolicy.EligibleRecords(batch)).Code);
        Assert.Equal(record.Id, Assert.Single(RetryPolicy.EligibleRecords(batch, unknownConfirmed: true)));
        record = record with { Attempts = [new RequestAttempt(Guid.NewGuid(), 10, DateTimeOffset.UtcNow, Digests.Sha256("payload"))] };
        Assert.Equal(DomainErrorCode.AttemptLimit,
            Assert.Throws<DomainException>(() => RetryPolicy.EligibleRecords(batch with { Records = [record] }, unknownConfirmed: true)).Code);
    }
}
