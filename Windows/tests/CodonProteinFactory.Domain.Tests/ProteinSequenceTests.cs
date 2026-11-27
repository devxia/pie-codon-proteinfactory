namespace CodonProteinFactory.Domain.Tests;

public sealed class ProteinSequenceTests
{
    [Fact]
    public void NormalizesOnlyAsciiResiduesAndIgnoresSequenceWhitespace()
    {
        var protein = ProteinSequence.Parse("\uFEFFacdefg\t hiklmn \u00A0pqr\uFEFFstvwy\r\n*");
        Assert.Equal("ACDEFGHIKLMNPQRSTVWY*", protein.Value);
        Assert.Equal(20, protein.ResidueCount);
        Assert.True(protein.HasTerminalStop);
        Assert.Same(protein, protein.Apply(StopPolicy.Add));
    }

    [Theory]
    [InlineData("B")]
    [InlineData("J")]
    [InlineData("O")]
    [InlineData("U")]
    [InlineData("X")]
    [InlineData("Z")]
    [InlineData("1")]
    [InlineData("-")]
    [InlineData("ß")]
    [InlineData("ſ")]
    [InlineData("K")]
    [InlineData("\0")]
    public void RejectsInvalidResidueAtItsNormalizedPosition(string residue)
    {
        var error = Assert.Throws<DomainException>(() => ProteinSequence.Parse($"A \t {residue}"));
        Assert.Equal(DomainErrorCode.InvalidResidue, error.Code);
        Assert.Equal(2, error.Position);
    }

    [Theory]
    [InlineData("*")]
    [InlineData("*A")]
    [InlineData("A* C")]
    [InlineData("A* *")]
    public void RejectsMisplacedStops(string input) =>
        Assert.Equal(DomainErrorCode.MisplacedStop, Assert.Throws<DomainException>(() => ProteinSequence.Parse(input)).Code);

    [Fact]
    public void ChecksLengthBeforeAndAfterAddingStop()
    {
        string full = new('A', 10_000);
        Assert.Equal(10_000, ProteinSequence.Parse(full).ResidueCount);
        Assert.Equal(DomainErrorCode.SequenceTooLong, Assert.Throws<DomainException>(() => ProteinSequence.Parse(full + "A")).Code);
        Assert.Equal(DomainErrorCode.StopExceedsLimit, Assert.Throws<DomainException>(() => ProteinSequence.Parse(full).Apply(StopPolicy.Add)).Code);
        Assert.Equal(full[..^1] + "*", ProteinSequence.Parse(full[..^1]).Apply(StopPolicy.Add).Value);
        Assert.Equal(DomainErrorCode.EmptySequence, Assert.Throws<DomainException>(() => ProteinSequence.Parse("\uFEFF \t\r\n")).Code);
    }
}
