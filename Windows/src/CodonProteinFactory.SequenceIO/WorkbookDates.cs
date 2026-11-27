using System.Globalization;
using System.Xml.Linq;

namespace CodonProteinFactory.SequenceIO;

internal sealed class WorkbookDates
{
    private enum Format { Date, Time, DateTime }
    private readonly DateOnly epoch;
    private readonly bool uses1904;
    private readonly int[] styles;
    private readonly Dictionary<int, Format> custom = [];

    public WorkbookDates(bool uses1904, XElement? styleSheet)
    {
        this.uses1904 = uses1904;
        epoch = uses1904 ? new DateOnly(1904, 1, 1) : new DateOnly(1899, 12, 31);
        XNamespace ns = styleSheet?.Name.Namespace ?? XNamespace.None;
        var formats = styleSheet?.Element(ns + "numFmts")?.Elements(ns + "numFmt") ?? [];
        foreach (var format in formats)
        {
            if (int.TryParse((string?)format.Attribute("numFmtId"), out int id) &&
                Recognize((string?)format.Attribute("formatCode") ?? string.Empty) is { } kind)
                custom[id] = kind;
        }
        styles = (styleSheet?.Element(ns + "cellXfs")?.Elements(ns + "xf") ?? [])
            .Select(style => int.TryParse((string?)style.Attribute("numFmtId"), out int id) ? id : 0).ToArray();
        SpreadsheetBudget.Require(custom.Count <= 65_536 && styles.Length <= 65_536);
    }

    public string Render(string input, int style)
    {
        if (style < 0 || style >= styles.Length || !double.TryParse(input, NumberStyles.Float, CultureInfo.InvariantCulture, out double serial) ||
            !double.IsFinite(serial) || serial < 0 || serial >= 2_958_466 || FindFormat(styles[style]) is not { } format)
            return input;
        int day = (int)serial;
        int seconds = (int)Math.Round((serial - day) * 86_400, MidpointRounding.AwayFromZero);
        string time = TimeOnly.FromTimeSpan(TimeSpan.FromSeconds(seconds % 86_400)).ToString("HH:mm:ss", CultureInfo.InvariantCulture);
        if (format == Format.Time) return time;
        int displayDay = day + seconds / 86_400;
        if (!uses1904 && displayDay == 60) return format == Format.Date ? "1900-02-29" : "1900-02-29 " + time;
        int ordinal = epoch.DayNumber + displayDay - (!uses1904 && displayDay > 60 ? 1 : 0);
        if (ordinal > DateOnly.MaxValue.DayNumber) return input;
        string date = DateOnly.FromDayNumber(ordinal).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        return format == Format.Date ? date : date + " " + time;
    }

    private Format? FindFormat(int id)
    {
        if (custom.TryGetValue(id, out var format)) return format;
        return id switch
        {
            >= 14 and <= 17 or >= 27 and <= 31 or >= 34 and <= 36 or >= 50 and <= 58 => Format.Date,
            >= 18 and <= 21 or >= 32 and <= 33 or 45 or 47 => Format.Time,
            22 => Format.DateTime,
            _ => null
        };
    }

    private static Format? Recognize(string code)
    {
        code = code.ToLowerInvariant();
        bool quoted = false;
        var tokens = new HashSet<char>();
        for (int i = 0; i < code.Length; i++)
        {
            char c = code[i];
            if (c == '"') { quoted = !quoted; continue; }
            if (quoted) continue;
            if (c == ';') break;
            if (c is '\\' or '_' or '*') { i++; continue; }
            if (c == '[')
            {
                int end = code.IndexOf(']', i + 1);
                if (end < 0 || code[(i + 1)..end] is "h" or "hh" or "m" or "mm" or "s" or "ss") return null;
                i = end;
                continue;
            }
            if (c is 'y' or 'd' or 'h' or 's' or 'm') tokens.Add(c);
        }
        bool hasDate = tokens.Contains('y') || tokens.Contains('d');
        bool hasTime = tokens.Contains('h') || tokens.Contains('s');
        if (hasTime) return hasDate ? Format.DateTime : Format.Time;
        return hasDate || tokens.Contains('m') ? Format.Date : null;
    }
}
