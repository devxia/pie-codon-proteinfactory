using System.Text;

namespace CodonProteinFactory.Domain;

public static class DomainLimits
{
    public const int MaxRecords = 200;
    public const int MaxSequenceLength = 10_000;
    public const int MaxBatchLength = 200_000;
    public const int MaxTextBytes = 5 * 1024 * 1024;
    public const int MaxAttempts = 10;
    public const int MaxBatchNameLength = 200;
    public const int MaxRecordNameLength = 300;
}

public sealed record ProteinSequence
{
    private const string AminoAcids = "ACDEFGHIKLMNPQRSTVWY";

    private ProteinSequence(string value) => Value = value;

    public string Value { get; }
    public bool HasTerminalStop => Value.EndsWith('*');
    public int ResidueCount => Value.Length - (HasTerminalStop ? 1 : 0);

    public static ProteinSequence Parse(string raw)
    {
        var residues = new StringBuilder(Math.Min(raw.Length, DomainLimits.MaxSequenceLength));
        foreach (var rune in raw.EnumerateRunes())
        {
            if (SequenceText.IsWhitespace(rune)) continue;

            int position = residues.Length + 1;
            if (residues.Length > 0 && residues[^1] == '*')
                throw new DomainException(DomainErrorCode.MisplacedStop, $"Stop must be terminal (position {position - 1}).", position - 1);

            int residue = SequenceText.UppercaseAscii(rune.Value);
            if (residue == '*' && position == 1)
                throw new DomainException(DomainErrorCode.MisplacedStop, "A stop cannot be the first residue.", position);
            if (residue != '*' && (residue > 127 || !AminoAcids.Contains((char)residue)))
                throw new DomainException(DomainErrorCode.InvalidResidue, $"Invalid amino acid at position {position}.", position);
            if (position > DomainLimits.MaxSequenceLength)
                throw new DomainException(DomainErrorCode.SequenceTooLong, $"Sequence exceeds {DomainLimits.MaxSequenceLength:N0} characters.");
            residues.Append((char)residue);
        }
        if (residues.Length == 0)
            throw new DomainException(DomainErrorCode.EmptySequence, "Enter a protein sequence.");
        return new ProteinSequence(residues.ToString());
    }

    public ProteinSequence Apply(StopPolicy policy)
    {
        if (policy != StopPolicy.Add || HasTerminalStop) return this;
        if (Value.Length == DomainLimits.MaxSequenceLength)
            throw new DomainException(DomainErrorCode.StopExceedsLimit, "Adding the stop would exceed the sequence limit.");
        return new ProteinSequence(Value + "*");
    }
}

public static class SequenceText
{
    public static bool IsWhitespace(Rune rune) => Rune.IsWhiteSpace(rune) || rune.Value == 0xFEFF;

    internal static int UppercaseAscii(int value) => value is >= 'a' and <= 'z' ? value - 32 : value;

    public static IEnumerable<string> Lines(string text)
    {
        int start = 0;
        for (int index = 0; index < text.Length; index++)
        {
            if (text[index] is not ('\r' or '\n' or '\v' or '\f' or '\u0085' or '\u2028' or '\u2029')) continue;
            yield return text[start..index];
            if (text[index] == '\r' && index + 1 < text.Length && text[index + 1] == '\n') index++;
            start = index + 1;
        }
        if (start < text.Length) yield return text[start..];
    }
}
