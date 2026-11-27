using System.IO.Compression;
using System.Text;
using CodonProteinFactory.Domain;

namespace CodonProteinFactory.SequenceIO.Tests;

public sealed class ImportTests
{
    [Fact]
    public void DelimitedPreviewKeepsPhysicalRowsAndValidRecords()
    {
        const string csv = "Name,Sequence,Notes\r\n  same  ,\"a\r\nc\",keep\r\n,a-x,bad\r\nlone\r\nsame,k*,keep\r\nonly,\r\n,,";
        var sheets = SequenceImport.ReadSpreadsheet(Encoding.UTF8.GetBytes(csv), ImportFormat.Csv);
        var rows = SequenceImport.MapColumns(sheets, new ColumnMapping(0, true, 0, 1));
        var preview = SequenceImport.Validate(rows, StopPolicy.Add);
        Assert.Equal([2, 4, 5, 6, 7], preview.Rows.Select(row => row.Input.SourceRow));
        Assert.Equal([0, 2, 1, 0, 1], preview.Rows.Select(row => row.Issues.Count));
        Assert.Equal(["AC*", "K*"], preview.Rows.Where(row => row.Issues.Count == 0).Select(row => row.Submitted!.Value));
        var batch = BatchPreparation.Prepare("Mixed", preview.ValidRecords);
        Assert.Equal(["same", "same"], batch.Records.Select(row => row.Name));
    }

    [Fact]
    public void AcceptsGb18030AndSemicolonWithoutConfusingQuotedColumns()
    {
        var encoding = CodePagesEncodingProvider.Instance.GetEncoding(54936)!;
        var sheets = SequenceImport.ReadSpreadsheet(encoding.GetBytes("名称;序列;备注\r\n样本;M;\"逗号,分号;\""), ImportFormat.Csv);
        Assert.Equal(["样本", "M", "逗号,分号;"], sheets[0].Rows[1]);
    }

    [Fact]
    public void TsvTracksMultilineRowsAndRejectsBrokenQuoting()
    {
        var book = SequenceImport.ReadSpreadsheet(Encoding.UTF8.GetBytes("Seq\tName\n\"A\nC\"\tone\nQ\ttwo"), ImportFormat.Tsv);
        Assert.Equal([1, 2, 4], book[0].SourceRows);
        var error = Assert.Throws<ImportException>(() => SequenceImport.ReadSpreadsheet("x\ty\n\"broken"u8.ToArray(), ImportFormat.Tsv));
        Assert.Equal(ImportErrorCode.MalformedDelimitedText, error.Code);
    }

    [Fact]
    public void ReadsFastaFixtureAndPreservesHeaderLineAndDuplicateNames()
    {
        var fixture = SequenceImport.ReadFasta(Fixture("proteins.faa"));
        Assert.NotEmpty(fixture);
        var rows = SequenceImport.ReadFasta("\uFEFF>one\r\nMk\r\n\r\n>one\r\nAc*\r\n");
        Assert.Equal(["one", "one"], rows.Select(row => row.Name));
        Assert.Equal([1, 4], rows.Select(row => row.SourceRow));
        Assert.Equal(["MK", "AC*"], SequenceImport.Validate(rows, StopPolicy.Preserve).Rows.Select(row => row.Original!.Value));
        var error = Assert.Throws<ImportException>(() => SequenceImport.ReadFasta(">one\nM\n\n>empty\n"));
        Assert.Equal(4, error.Row);
    }

    [Fact]
    public void MapsSparseWorkbookByWorksheetAndKeepsEmptyRowsOutOfPreview()
    {
        var sheets = SequenceImport.ReadSpreadsheet(Fixture("sparse-import.xlsx"), ImportFormat.Xlsx);
        Assert.Equal(["Names first", "Sequences first"], sheets.Take(2).Select(sheet => sheet.Name));
        var selected = SequenceImport.MapColumns(sheets, new ColumnMapping(1, true, 1, 0));
        Assert.Equal([4, 7], selected.Select(row => row.SourceRow));
        Assert.Equal(["repeat", "repeat"], selected.Select(row => row.Name));
        Assert.Equal(["AQ", "W*"], SequenceImport.Validate(selected, StopPolicy.Preserve).Rows.Select(row => row.Original!.Value));
    }

    [Fact]
    public void RendersBothWorkbookDateSystemsAndReadsCachedFormulas()
    {
        var base1900 = SequenceImport.ReadSpreadsheet(Fixture("workbook-1900.xlsx"), ImportFormat.Xlsx)[0];
        var base1904 = SequenceImport.ReadSpreadsheet(Fixture("workbook-1904.xlsx"), ImportFormat.Xlsx)[0];
        Assert.Equal("样本表", base1900.Name);
        Assert.True(base1900.ContainsFormulas);
        Assert.Equal("标签", base1900.Rows[0][0]);
        Assert.Equal(string.Empty, base1900.Rows[0][1]);
        Assert.Equal("5", base1900.Rows[0][3]);
        Assert.Equal(string.Empty, base1900.Rows[0][5]);
        Assert.Equal("north", base1900.Rows[0][11]);
        Assert.Equal(base1900.Rows[0][7], base1904.Rows[2][2]);
        Assert.NotEqual(base1900.Rows[0][7], base1900.Rows[0][10]);
    }

    [Fact]
    public void RejectsDtdAndZipTraversalAsInvalidWorkbooks()
    {
        byte[] dtd = Zip("_rels/.rels", "<!DOCTYPE r [<!ENTITY e 'unsafe'>]><r>&e;</r>");
        byte[] traversal = Zip("../_rels/.rels", "x");
        foreach (byte[] workbook in new[] { dtd, traversal })
        {
            var error = Assert.Throws<ImportException>(() => SequenceImport.ReadSpreadsheet(workbook, ImportFormat.Xlsx));
            Assert.Equal(ImportErrorCode.InvalidWorkbook, error.Code);
        }
    }

    [Fact]
    public void EnforcesImportLimitsAtTheExactBoundary()
    {
        Assert.Single(SequenceImport.ReadFasta(new string(' ', DomainLimits.MaxTextBytes - 1) + "A"));
        Assert.Equal(ImportErrorCode.FileTooLarge,
            Assert.Throws<ImportException>(() => SequenceImport.ReadFasta(new string(' ', DomainLimits.MaxTextBytes) + "A")).Code);
        string limit = new('A', 32_767);
        Assert.Equal(limit, SequenceImport.ReadSpreadsheet(Encoding.UTF8.GetBytes(limit), ImportFormat.Csv)[0].Rows[0][0]);
        Assert.Equal(ImportErrorCode.LimitExceeded, Assert.Throws<ImportException>(() =>
            SequenceImport.ReadSpreadsheet(Encoding.UTF8.GetBytes(limit + "A"), ImportFormat.Csv)).Code);
        Assert.Equal(ImportErrorCode.LimitExceeded, Assert.Throws<ImportException>(() =>
            SequenceImport.ReadSpreadsheet(Zip("_rels/.rels", new string('X', 40 * 1024 * 1024 + 1)), ImportFormat.Xlsx)).Code);
    }

    private static byte[] Fixture(string name) => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    private static byte[] Zip(string path, string text)
    {
        using var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        using (var writer = new StreamWriter(archive.CreateEntry(path).Open())) writer.Write(text);
        return stream.ToArray();
    }
}
