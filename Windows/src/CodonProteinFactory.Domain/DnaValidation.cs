using System.Text;

namespace CodonProteinFactory.Domain;

public sealed record DnaChecks(int BasePairCount, int AminoAcidCount, double GcPercent, bool HasTerminalStop, int CheckedMotifCount);
public sealed record VerifiedDna(string Dna, string Sha256, DnaChecks Checks);
public sealed record CodonComparison(int Position, char Expected, string Codon, char? Translated);

public static class DnaValidation
{
    private const string Bases = "ACGT";
    private const string CodonTable = "KNKNTTTTRSRSIIMI" + "QHQHPPPPRRRRLLLL" + "EDEDAAAAGGGGVVVV" + "*Y*YSSSS*CWCLFLF";

    public static VerifiedDna Verify(string dna, ProteinSequence sequence,
        AvoidMotifs? avoid = null, StartCodonPolicy startPolicy = StartCodonPolicy.None)
    {
        if (dna.Length == 0) throw new DomainException(DomainErrorCode.EmptyDna, "The result is empty.");
        int prefixLength = startPolicy.PrefixLength(sequence);
        int expected = sequence.Value.Length * 3 + prefixLength;
        byte[] bytes = Encoding.UTF8.GetBytes(dna);
        int gc = 0;
        for (int index = 0; index < bytes.Length; index++)
        {
            char value = (char)SequenceText.UppercaseAscii(bytes[index]);
            if (!Bases.Contains(value))
                throw new DomainException(DomainErrorCode.InvalidBase, $"Invalid DNA base at position {index + 1}.", index + 1);
            if (value is 'G' or 'C') gc++;
            bytes[index] = (byte)value;
        }
        CheckLength(expected, bytes.Length);
        string normalized = Encoding.ASCII.GetString(bytes);
        if (prefixLength > 0 && !normalized.StartsWith("ATG", StringComparison.Ordinal))
            throw Mismatch(0, 'M', Translate(normalized.AsSpan(0, 3))!.Value);
        for (int index = 0; index < sequence.Value.Length; index++)
        {
            char residue = sequence.Value[index];
            char actual = Translate(normalized.AsSpan(prefixLength + index * 3, 3))!.Value;
            if (residue == actual) continue;
            int position = index + 1;
            if (actual == '*')
                throw new DomainException(DomainErrorCode.UnexpectedStop, $"Unexpected stop at residue {position}.", position);
            if (residue == '*')
                throw new DomainException(DomainErrorCode.MissingTerminalStop, $"Missing terminal stop at residue {position}.", position);
            throw Mismatch(position, residue, actual);
        }

        var motifs = (avoid ?? AvoidMotifs.Empty).Motifs;
        foreach (string motif in motifs)
        {
            if (normalized.Contains(motif, StringComparison.Ordinal))
                throw new DomainException(DomainErrorCode.ForbiddenMotif, $"Result contains avoided motif {motif} (forward)." );
            string reverse = string.Create(motif.Length, motif, (destination, source) =>
            {
                for (int i = 0; i < source.Length; i++) destination[i] = Bases[3 - Bases.IndexOf(source[^(i + 1)])];
            });
            if (reverse != motif && normalized.Contains(reverse, StringComparison.Ordinal))
                throw new DomainException(DomainErrorCode.ForbiddenMotif, $"Result contains avoided motif {motif} (reverse complement).");
        }
        return new VerifiedDna(normalized, Digests.Sha256(bytes),
            new DnaChecks(bytes.Length, sequence.ResidueCount, (double)gc / bytes.Length * 100, sequence.HasTerminalStop, motifs.Count));
    }

    public static IReadOnlyList<CodonComparison> CompareCodons(string dna, ProteinSequence sequence, StartCodonPolicy policy)
    {
        int prefix = policy.PrefixLength(sequence);
        byte[] bytes = Encoding.UTF8.GetBytes(dna);
        CheckLength(sequence.Value.Length * 3 + prefix, bytes.Length);
        var comparisons = new List<CodonComparison>(bytes.Length / 3);
        for (int offset = 0; offset < bytes.Length; offset += 3)
        {
            string codon = Encoding.UTF8.GetString(bytes, offset, 3);
            int position = (offset - prefix) / 3 + 1;
            comparisons.Add(new CodonComparison(position, position == 0 ? 'M' : sequence.Value[position - 1], codon, Translate(codon)));
        }
        return comparisons.AsReadOnly();
    }

    public static VerifiedDna Reverify(SequenceRecord record, OptimizationParameters parameters)
    {
        if (record.Status != RecordStatus.Completed || record.Dna is null || record.DnaSha256 is null)
            throw new DomainException(DomainErrorCode.MissingDna, "Completed result is missing DNA or a verification hash.", record.Position);
        if (Digests.Sha256(record.Dna) != record.DnaSha256)
            throw new DomainException(DomainErrorCode.DnaHashMismatch, "The saved DNA does not match its verification hash.", record.Position);
        return Verify(record.Dna, record.Sequence, parameters.Avoid, parameters.StartPolicy);
    }

    private static char? Translate(ReadOnlySpan<char> codon)
    {
        if (codon.Length != 3) return null;
        int first = Bases.IndexOf((char)SequenceText.UppercaseAscii(codon[0]));
        int second = Bases.IndexOf((char)SequenceText.UppercaseAscii(codon[1]));
        int third = Bases.IndexOf((char)SequenceText.UppercaseAscii(codon[2]));
        return first < 0 || second < 0 || third < 0 ? null : CodonTable[first * 16 + second * 4 + third];
    }

    private static void CheckLength(int expected, int actual)
    {
        if (actual != expected)
            throw new DomainException(DomainErrorCode.IncorrectDnaLength, $"Expected {expected} DNA bases but got {actual}.");
    }

    private static DomainException Mismatch(int position, char expected, char actual) =>
        new(DomainErrorCode.TranslationMismatch, $"Position {position} translates to {actual}, expected {expected}.", position);
}
