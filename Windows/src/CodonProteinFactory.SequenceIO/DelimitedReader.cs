using System.Text;

namespace CodonProteinFactory.SequenceIO;

internal static class DelimitedReader
{
    private enum FieldState { Start, Unquoted, Quoted, AfterQuote }

    public static Sheet Read(byte[] bytes, bool tsv)
    {
        string text = Decode(bytes);
        char delimiter = tsv ? '\t' : DetectDelimiter(text);
        var rows = new List<string[]>();
        var sourceRows = new List<int>();
        var budget = new SpreadsheetBudget();
        var fields = new List<string>();
        var value = new StringBuilder();
        int columns = 0;
        bool hasData = false;
        Scan(text.AsSpan(), delimiter, true, valueChar =>
        {
            SpreadsheetBudget.Require(value.Length < SpreadsheetBudget.MaxCellLength);
            value.Append(valueChar);
        }, () =>
        {
            SpreadsheetBudget.Require(fields.Count < SpreadsheetBudget.MaxColumns);
            string cell = value.ToString();
            budget.Add(cell);
            fields.Add(cell);
            hasData |= cell.Length != 0;
            value.Clear();
        }, line =>
        {
            SpreadsheetBudget.Require(rows.Count < SpreadsheetBudget.MaxRows);
            columns = Math.Max(columns, fields.Count);
            rows.Add(fields.ToArray());
            fields.Clear();
            sourceRows.Add(line);
        });
        if (!hasData) throw new ImportException(ImportErrorCode.EmptyData, "The delimited file contains no data.");
        return new Sheet(null, rows.AsReadOnly(), sourceRows.AsReadOnly(), columns, false);
    }

    private static string Decode(byte[] bytes)
    {
        if (Array.IndexOf(bytes, (byte)0) >= 0) throw new ImportException(ImportErrorCode.InvalidEncoding, "The file contains NUL bytes.");
        bool bom = bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf });
        try { return SequenceImport.StrictUtf8.GetString(bytes.AsSpan(bom ? 3 : 0)); }
        catch (DecoderFallbackException utf8Error)
        {
            if (bom) throw new ImportException(ImportErrorCode.InvalidEncoding, "The UTF-8 file contains invalid bytes.", inner: utf8Error);
            try
            {
                var encoding = CodePagesEncodingProvider.Instance.GetEncoding(54936, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback)!;
                return encoding.GetString(bytes);
            }
            catch (DecoderFallbackException error)
            {
                throw new ImportException(ImportErrorCode.InvalidEncoding, "Expected UTF-8 or GB18030.", inner: error);
            }
        }
    }

    private static char DetectDelimiter(string text)
    {
        int sampleLength = 0;
        int scalarCount = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (scalarCount++ == 8192) break;
            sampleLength += rune.Utf16SequenceLength;
        }
        char best = ',';
        var score = (Matches: 0, NegativeMismatches: int.MinValue, Width: 0);
        foreach (char delimiter in new[] { ',', ';', '\t' })
        {
            var widths = new Dictionary<int, int>();
            int columns = 0;
            int rows = 0;
            bool hasContent = false;
            try
            {
                Scan(text.AsSpan(0, sampleLength), delimiter, sampleLength == text.Length, _ => hasContent = true,
                    () => columns++, _ =>
                    {
                        if (hasContent || columns > 1)
                        {
                            widths[columns] = widths.GetValueOrDefault(columns) + 1;
                            rows++;
                        }
                        columns = 0;
                        hasContent = false;
                    });
            }
            catch (ImportException) { /* Delimiter detection uses complete rows before the malformed field. */ }
            foreach (var (width, matches) in widths)
            {
                var candidate = (matches, matches - rows, width);
                if (width <= 1 || candidate.CompareTo(score) <= 0) continue;
                score = candidate;
                best = delimiter;
            }
        }
        return best;
    }

    private static void Scan(ReadOnlySpan<char> text, char delimiter, bool complete, Action<char> character,
        Action field, Action<int> row)
    {
        FieldState state = FieldState.Start;
        int line = 1;
        int firstLine = 1;
        bool pending = false;
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (state == FieldState.Quoted)
            {
                if (c == '"') { state = FieldState.AfterQuote; continue; }
                character(c);
                if (c is '\r' or '\n') line++;
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') character(text[++i]);
                continue;
            }
            if (c == delimiter)
            {
                field();
                state = FieldState.Start;
                pending = true;
            }
            else if (c is '\r' or '\n')
            {
                if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                field();
                row(firstLine);
                firstLine = ++line;
                state = FieldState.Start;
                pending = false;
            }
            else if (c == '"')
            {
                if (state == FieldState.Unquoted) throw Malformed(line);
                if (state == FieldState.AfterQuote) character(c);
                state = FieldState.Quoted;
                pending = true;
            }
            else
            {
                if (state == FieldState.AfterQuote) throw Malformed(line);
                character(c);
                state = FieldState.Unquoted;
                pending = true;
            }
        }
        if (!complete) return;
        if (state == FieldState.Quoted) throw Malformed(line);
        if (!pending) return;
        field();
        row(firstLine);
    }

    private static ImportException Malformed(int line) => new(ImportErrorCode.MalformedDelimitedText, $"Invalid quoting on line {line}.", line);
}
