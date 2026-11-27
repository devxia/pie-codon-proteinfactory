using System.Text.Json;

namespace CodonProteinFactory.Domain.Tests;

public sealed class DnaValidationTests
{
    [Fact]
    public void VerifiesEveryCodonAgainstTheStandardGeneticCode()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "codon-table.json")));
        string bases = fixture.RootElement.GetProperty("baseOrder").GetString()!;
        string codes = fixture.RootElement.GetProperty("translations").GetString()!;
        Assert.Equal(64, codes.Length);
        int index = 0;
        foreach (char first in bases)
        foreach (char second in bases)
        foreach (char third in bases)
        {
            char expected = codes[index++];
            string codon = new([first, second, third]);
            var protein = ProteinSequence.Parse(expected == '*' ? "A*" : expected.ToString());
            string dna = expected == '*' ? "GCT" + codon : codon;
            var verification = DnaValidation.Verify(dna.ToLowerInvariant(), protein);
            Assert.Equal(dna, verification.Dna);
            Assert.Equal(expected == '*', verification.Checks.HasTerminalStop);
        }
    }

    [Theory]
    [InlineData("A", "ATGGCT", StartCodonPolicy.IfNotMethionine, 2)]
    [InlineData("M*", "ATGTAA", StartCodonPolicy.IfNotMethionine, 2)]
    [InlineData("M*", "ATGATGTAG", StartCodonPolicy.Always, 3)]
    public void ReportsDnaOnlyPrefixWithoutChangingResiduePositions(string protein, string dna, StartCodonPolicy policy, int codons)
    {
        var sequence = ProteinSequence.Parse(protein);
        Assert.Equal(dna, DnaValidation.Verify(dna, sequence, startPolicy: policy).Dna);
        var comparison = DnaValidation.CompareCodons(dna, sequence, policy);
        Assert.Equal(codons, comparison.Count);
        Assert.Equal(policy.PrefixLength(sequence) == 0 ? 1 : 0, comparison[0].Position);
    }

    [Theory]
    [InlineData("", "A", DomainErrorCode.EmptyDna)]
    [InlineData("GC?", "A", DomainErrorCode.InvalidBase)]
    [InlineData("GCTTAA", "A", DomainErrorCode.IncorrectDnaLength)]
    [InlineData("TAA", "M", DomainErrorCode.UnexpectedStop)]
    [InlineData("ATGATG", "M*", DomainErrorCode.MissingTerminalStop)]
    [InlineData("AAA", "M", DomainErrorCode.TranslationMismatch)]
    public void DifferentiatesInvalidResults(string dna, string protein, DomainErrorCode code) =>
        Assert.Equal(code, Assert.Throws<DomainException>(() => DnaValidation.Verify(dna, ProteinSequence.Parse(protein))).Code);

    [Theory]
    [InlineData("GCT", "forward")]
    [InlineData("AGC", "reverse complement")]
    public void RejectsAvoidedMotifsOnEitherStrand(string motif, string orientation)
    {
        var error = Assert.Throws<DomainException>(() => DnaValidation.Verify("GCT", ProteinSequence.Parse("A"), AvoidMotifs.Parse(motif)));
        Assert.Equal(DomainErrorCode.ForbiddenMotif, error.Code);
        Assert.Contains(orientation, error.Message, StringComparison.Ordinal);
    }
}
