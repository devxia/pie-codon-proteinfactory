using System.Text;

namespace CodonProteinFactory.Domain;

public enum Species
{
    DefaultD2P, EscherichiaColi, ChineseHamsterOvary, PichiaPastoris, SaccharomycesCerevisiae,
    BacillusSubtilis, ClostridiumAcetobutylicum, KluyveromycesLactis, PseudomonasFluorescens
}

public enum StopPolicy { Preserve, Add }
public enum StartCodonPolicy { None, Always, IfNotMethionine }
public enum RestrictionEnzyme { EcoRI, BamHI, HindIII, BsaI, BsmBI, NotI, NdeI, XhoI }

public static class ParameterValues
{
    public static string WireValue(this Species species) => species switch
    {
        Species.DefaultD2P => "D2P(default)",
        Species.EscherichiaColi => "Escherichia_coli",
        Species.ChineseHamsterOvary => "Chinsese_hamster_ovary(CHO)_cells",
        Species.PichiaPastoris => "Pichia_pastoris",
        Species.SaccharomycesCerevisiae => "Saccharomyces_cerevisiae",
        Species.BacillusSubtilis => "Bacillus_subtilis",
        Species.ClostridiumAcetobutylicum => "Clostridium_acetobutylicum",
        Species.KluyveromycesLactis => "Kluyveromyces_lactis",
        Species.PseudomonasFluorescens => "Pseudomonas_fluorescens",
        _ => throw new ArgumentOutOfRangeException(nameof(species))
    };

    public static string DisplayName(this Species species) => species switch
    {
        Species.DefaultD2P => "D2P (default)",
        Species.ChineseHamsterOvary => "Chinese hamster ovary (CHO) cells",
        _ => species.WireValue().Replace('_', ' ')
    };

    public static string Motif(this RestrictionEnzyme enzyme) => enzyme switch
    {
        RestrictionEnzyme.EcoRI => "GAATTC", RestrictionEnzyme.BamHI => "GGATCC",
        RestrictionEnzyme.HindIII => "AAGCTT", RestrictionEnzyme.BsaI => "GGTCTC",
        RestrictionEnzyme.BsmBI => "CGTCTC", RestrictionEnzyme.NotI => "GCGGCCGC",
        RestrictionEnzyme.NdeI => "CATATG", RestrictionEnzyme.XhoI => "CTCGAG",
        _ => throw new ArgumentOutOfRangeException(nameof(enzyme))
    };

    public static int PrefixLength(this StartCodonPolicy policy, ProteinSequence sequence) => policy switch
    {
        StartCodonPolicy.None => 0,
        StartCodonPolicy.Always => 3,
        StartCodonPolicy.IfNotMethionine => sequence.Value[0] == 'M' ? 0 : 3,
        _ => throw new ArgumentOutOfRangeException(nameof(policy))
    };
}

public sealed record AvoidMotifs
{
    public const int MaximumCustomLength = 2_000;
    public static AvoidMotifs Empty { get; } = new(string.Empty);
    public string WireValue { get; }
    public IReadOnlyList<string> Motifs => WireValue.Split(',', StringSplitOptions.RemoveEmptyEntries);

    private AvoidMotifs(string wireValue) => WireValue = wireValue;

    public static AvoidMotifs Parse(string raw, IEnumerable<RestrictionEnzyme>? enzymes = null)
    {
        if (raw.Length > MaximumCustomLength)
            throw new DomainException(DomainErrorCode.MotifsTooLong, $"Motifs exceed {MaximumCustomLength:N0} UTF-16 units.");

        var compact = new StringBuilder(raw.Length);
        foreach (var rune in raw.EnumerateRunes())
        {
            if (SequenceText.IsWhitespace(rune)) continue;
            compact.Append(new Rune(SequenceText.UppercaseAscii(rune.Value)).ToString());
        }
        var motifs = new List<string>();
        string[] tokens = compact.ToString().Split([',', '，', ';', '；'], StringSplitOptions.RemoveEmptyEntries);
        for (int index = 0; index < tokens.Length; index++)
        {
            string token = tokens[index];
            if (token == "GGT(A/T)ACC")
            {
                motifs.Add("GGTAACC");
                motifs.Add("GGTTACC");
            }
            else
            {
                ValidateToken(token, index + 1);
                motifs.Add(token);
            }
        }
        if (enzymes is not null) motifs.AddRange(enzymes.Select(ParameterValues.Motif));
        return new AvoidMotifs(string.Join(',', motifs.Distinct(StringComparer.Ordinal)));
    }

    public static AvoidMotifs FromWireValue(string value)
    {
        if (value.Length == 0) return Empty;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int position = 0;
        foreach (string token in value.Split(','))
        {
            position++;
            ValidateToken(token, position);
            if (!seen.Add(token))
                throw new DomainException(DomainErrorCode.InvalidMotif, $"Duplicate motif at position {position}.", position);
        }
        return new AvoidMotifs(value);
    }

    private static void ValidateToken(string token, int position)
    {
        if (token.Length == 0 || token.Any(c => c is not ('A' or 'C' or 'G' or 'T')))
            throw new DomainException(DomainErrorCode.InvalidMotif, $"Invalid DNA motif at position {position}.", position);
    }
}

public sealed record OptimizationParameters
{
    public Species Species { get; init; } = Species.DefaultD2P;
    public StartCodonPolicy StartPolicy { get; init; } = StartCodonPolicy.None;
    public StopPolicy StopPolicy { get; init; } = StopPolicy.Preserve;
    public AvoidMotifs Avoid { get; init; } = AvoidMotifs.Empty;
}
