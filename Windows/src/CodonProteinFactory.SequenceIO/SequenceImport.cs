using System.Globalization;
using System.Text;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.SequenceIO;

public static class SequenceImport
{
    internal static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);

    public static ImportFormat DetectFormat(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".fa" or ".faa" or ".fas" or ".fasta" or ".txt" => ImportFormat.Fasta,
        ".csv" => ImportFormat.Csv,
        ".tsv" => ImportFormat.Tsv,
        ".xlsx" => ImportFormat.Xlsx,
        ".xls" => throw new ImportException(ImportErrorCode.UnsupportedFile, "Save the legacy workbook as XLSX or CSV before importing."),
        _ => throw new ImportException(ImportErrorCode.UnsupportedFile, "Choose a FASTA, CSV, TSV, or XLSX file.")
    };

    public static async Task<byte[]> ReadFileAsync(string path, CancellationToken cancellationToken = default)
    {
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.Asynchronous);
        CheckSize(file.Length);
        var bytes = new byte[file.Length];
        await file.ReadExactlyAsync(bytes, cancellationToken);
        return bytes;
    }

    public static IReadOnlyList<ImportRow> ReadFasta(byte[] bytes, string? defaultName = null)
    {
        CheckSize(bytes.Length);
        try { return ReadFasta(StrictUtf8.GetString(bytes), defaultName); }
        catch (DecoderFallbackException error) { throw new ImportException(ImportErrorCode.InvalidEncoding, "FASTA must be UTF-8.", inner: error); }
    }

    public static IReadOnlyList<ImportRow> ReadFasta(string text, string? defaultName = null)
    {
        CheckSize(Encoding.UTF8.GetByteCount(text));
        if (text.Contains('\0') || defaultName?.Contains('\0') == true)
            throw new ImportException(ImportErrorCode.MalformedFasta, "The FASTA input contains a NUL character.");
        if (text.StartsWith('\uFEFF')) text = text[1..];
        var records = new List<ImportRow>();
        string? header = null;
        int lineNumber = 0;
        int start = 0;
        var sequence = new StringBuilder();
        foreach (string line in text.Split('\n'))
        {
            lineNumber++;
            string content = line.TrimStart();
            if (content.Length == 0) continue;
            if (content.StartsWith('>'))
            {
                if (line[0] != '>') throw new ImportException(ImportErrorCode.MalformedFasta, "A FASTA header must start at the beginning of the line.", lineNumber);
                if (header is not null) AppendRecord(header);
                else if (start != 0) throw new ImportException(ImportErrorCode.MalformedFasta, "Sequence data appears before the first FASTA header.", start);
                header = FoldHeader(content[1..]);
                if (header.Length == 0) throw new ImportException(ImportErrorCode.MalformedFasta, "A FASTA header is missing a name.", lineNumber);
                start = lineNumber;
            }
            else
            {
                if (start == 0) start = lineNumber;
                foreach (var rune in content.EnumerateRunes())
                    if (!Rune.IsWhiteSpace(rune)) sequence.Append(rune.ToString());
            }
        }
        if (start == 0) throw new ImportException(ImportErrorCode.EmptyData, "Enter or import a protein sequence.");
        string name = header ?? FoldHeader(defaultName ?? string.Empty);
        AppendRecord(name.Length == 0 ? "Protein 1" : name);
        return records.AsReadOnly();

        void AppendRecord(string name)
        {
            if (sequence.Length == 0) throw new ImportException(ImportErrorCode.MalformedFasta, "A FASTA record has no sequence.", start);
            records.Add(new ImportRow(start, name, sequence.ToString()));
            sequence.Clear();
        }
    }

    public static IReadOnlyList<Sheet> ReadSpreadsheet(byte[] data, ImportFormat format)
    {
        CheckSize(data.Length);
        IReadOnlyList<Sheet> sheets = format switch
        {
            ImportFormat.Csv or ImportFormat.Tsv => [DelimitedReader.Read(data, format == ImportFormat.Tsv)],
            ImportFormat.Xlsx => WorkbookReader.Read(data),
            _ => throw new ImportException(ImportErrorCode.UnsupportedFile, "Choose a CSV, TSV, or XLSX file.")
        };
        if (!sheets.Any(sheet => sheet.Rows.Count != 0)) throw new ImportException(ImportErrorCode.EmptyData, "The spreadsheet contains no data.");
        return sheets;
    }

    public static IReadOnlyList<ImportRow> MapColumns(IReadOnlyList<Sheet> sheets, ColumnMapping mapping)
    {
        if (mapping.WorksheetIndex < 0 || mapping.WorksheetIndex >= sheets.Count)
            throw new ImportException(ImportErrorCode.InvalidMapping, "Choose an available worksheet.");
        var sheet = sheets[mapping.WorksheetIndex];
        if (mapping.NameColumn < 0 || mapping.NameColumn >= sheet.ColumnCount || mapping.SequenceColumn < 0 ||
            mapping.SequenceColumn >= sheet.ColumnCount || mapping.NameColumn == mapping.SequenceColumn)
            throw new ImportException(ImportErrorCode.InvalidMapping, "Choose different columns for name and protein sequence.");
        var records = new List<ImportRow>();
        for (int index = mapping.FirstRowIsHeader ? 1 : 0; index < sheet.Rows.Count; index++)
        {
            var row = sheet.Rows[index];
            if (row.All(cell => cell.EnumerateRunes().All(SequenceText.IsWhitespace))) continue;
            records.Add(new ImportRow(sheet.SourceRows[index], row.ElementAtOrDefault(mapping.NameColumn), row.ElementAtOrDefault(mapping.SequenceColumn)));
        }
        if (records.Count == 0) throw new ImportException(ImportErrorCode.EmptyData, "The selected worksheet contains no data rows.");
        return records.AsReadOnly();
    }

    public static ImportPreview Validate(IEnumerable<ImportRow> inputs, StopPolicy stopPolicy)
    {
        return new ImportPreview(inputs.Select(input =>
        {
            var issues = new List<string>();
            ProteinSequence? original = null;
            ProteinSequence? submitted = null;
            if (input.Name is null) issues.Add("The name cell is missing.");
            else if (BatchPreparation.ValidatedRecordName(input.Name) is null) issues.Add("The record name is invalid.");
            if (input.Sequence is null) issues.Add("The sequence cell is missing.");
            else
            {
                try
                {
                    original = ProteinSequence.Parse(input.Sequence);
                    submitted = original.Apply(stopPolicy);
                }
                catch (DomainException error) { issues.Add(error.Message); }
            }
            return new RowValidation(input, original, submitted, issues.AsReadOnly());
        }).ToArray());
    }

    private static void CheckSize(long size)
    {
        if (size == 0) throw new ImportException(ImportErrorCode.EmptyFile, "The input is empty.");
        if (size > DomainLimits.MaxTextBytes) throw new ImportException(ImportErrorCode.FileTooLarge, "The input exceeds 5 MiB.");
    }

    private static string FoldHeader(string value)
    {
        var output = new StringBuilder();
        bool space = false;
        foreach (var rune in value.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune) || Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format)
            {
                space = output.Length > 0;
                continue;
            }
            if (space) output.Append(' ');
            output.Append(rune.Value == '>' ? "_" : rune.ToString());
            space = false;
        }
        return output.ToString();
    }
}
