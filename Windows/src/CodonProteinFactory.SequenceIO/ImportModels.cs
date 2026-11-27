using CodonProteinFactory.Domain;

namespace CodonProteinFactory.SequenceIO;

public enum ImportErrorCode
{
    UnsupportedFile, EmptyFile, FileTooLarge, InvalidEncoding, EmptyData, MalformedFasta,
    MalformedDelimitedText, InvalidWorkbook, LimitExceeded, InvalidMapping
}

public sealed class ImportException(ImportErrorCode code, string message, int? row = null, Exception? inner = null)
    : Exception(message, inner)
{
    public ImportErrorCode Code { get; } = code;
    public int? Row { get; } = row;
}

public enum ImportFormat { Fasta, Csv, Tsv, Xlsx }
public sealed record Sheet(string? Name, IReadOnlyList<string[]> Rows, IReadOnlyList<int> SourceRows, int ColumnCount, bool ContainsFormulas);
public sealed record ColumnMapping(int WorksheetIndex, bool FirstRowIsHeader, int NameColumn, int SequenceColumn);
public sealed record ImportPreset(Guid Id, string Name, ColumnMapping Mapping);
public sealed record ImportRow(int SourceRow, string? Name, string? Sequence);
public sealed record RowValidation(ImportRow Input, ProteinSequence? Original, ProteinSequence? Submitted, IReadOnlyList<string> Issues);
public sealed record ImportPreview(IReadOnlyList<RowValidation> Rows)
{
    public IReadOnlyList<SequenceRecordInput> ValidRecords => Rows.Where(row => row.Issues.Count == 0)
        .Select(row => new SequenceRecordInput(row.Input.Name!, row.Input.Sequence!, row.Input.SourceRow)).ToArray();
}

internal sealed class SpreadsheetBudget
{
    public const int MaxSheets = 20;
    public const int MaxRows = 2_000;
    public const int MaxColumns = 100;
    public const int MaxCells = 100_000;
    public const int MaxCellLength = 32_767;
    public const int MaxTextBytes = 8 * 1024 * 1024;
    private int cells;
    private int bytes;

    public void Add(string value)
    {
        cells++;
        bytes += System.Text.Encoding.UTF8.GetByteCount(value);
        Require(cells <= MaxCells && value.Length <= MaxCellLength && bytes <= MaxTextBytes);
    }

    public static void Require(bool condition)
    {
        if (!condition) throw new ImportException(ImportErrorCode.LimitExceeded, "The spreadsheet exceeds an import limit.");
    }
}
