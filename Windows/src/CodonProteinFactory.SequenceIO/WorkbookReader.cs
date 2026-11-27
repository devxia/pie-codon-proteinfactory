using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace CodonProteinFactory.SequenceIO;

internal static class WorkbookReader
{
    private const string Main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string StrictMain = "http://purl.oclc.org/ooxml/spreadsheetml/main";
    private const string Package = "http://schemas.openxmlformats.org/package/2006/relationships";
    private const string StrictPackage = "http://purl.oclc.org/ooxml/package/relationships";
    private const string DocumentRelations = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string StrictDocumentRelations = "http://purl.oclc.org/ooxml/officeDocument/relationships";

    public static IReadOnlyList<Sheet> Read(byte[] bytes)
    {
        try
        {
            using var archive = new WorkbookArchive(bytes);
            var root = Relationships(archive, null).Values.SingleOrDefault(x => x.Kind == "officeDocument") ?? throw WorkbookArchive.Invalid();
            string workbookPart = root.Resolve(null);
            var workbook = archive.ReadXml(workbookPart, "workbook", Main, StrictMain);
            var parts = Relationships(archive, workbookPart);
            XNamespace ns = workbook.Name.Namespace;
            var sheets = workbook.Element(ns + "sheets")?.Elements(ns + "sheet").ToArray() ?? [];
            SpreadsheetBudget.Require(sheets.Length <= SpreadsheetBudget.MaxSheets);
            bool uses1904 = (string?)workbook.Element(ns + "workbookPr")?.Attribute("date1904") is "1" or "true";
            var styles = OptionalPart("styles", "styleSheet");
            var dates = new WorkbookDates(uses1904, styles);
            var shared = ReadStrings(OptionalPart("sharedStrings", "sst"));
            var budget = new SpreadsheetBudget();
            var result = new List<Sheet>();
            var used = new HashSet<string>(StringComparer.Ordinal);
            foreach (var sheet in sheets)
            {
                string? name = (string?)sheet.Attribute("name");
                string? id = (string?)sheet.Attribute(XName.Get("id", DocumentRelations)) ?? (string?)sheet.Attribute(XName.Get("id", StrictDocumentRelations));
                if (string.IsNullOrEmpty(name) || id is null || !parts.TryGetValue(id, out var relationship)) throw WorkbookArchive.Invalid();
                if (relationship.Kind != "worksheet") continue;
                string part = relationship.Resolve(workbookPart);
                if (!used.Add(part)) throw WorkbookArchive.Invalid();
                result.Add(ReadSheet(archive.ReadXml(part, "worksheet", Main, StrictMain), name, shared, dates, budget));
            }
            return result.AsReadOnly();

            XElement? OptionalPart(string kind, string rootName)
            {
                var relationship = parts.Values.SingleOrDefault(value => value.Kind == kind);
                return relationship is null ? null : archive.ReadXml(relationship.Resolve(workbookPart), rootName, Main, StrictMain);
            }
        }
        catch (Exception error) when (error is InvalidDataException or XmlException or IOException or InvalidOperationException or UriFormatException)
        {
            throw WorkbookArchive.Invalid(error);
        }
    }

    private static Dictionary<string, Relationship> Relationships(WorkbookArchive archive, string? source)
    {
        string path = "_rels/.rels";
        if (source is not null)
        {
            int index = source.LastIndexOf('/') + 1;
            path = source[..index] + "_rels/" + source[index..] + ".rels";
        }
        var root = archive.ReadXml(path, "Relationships", Package, StrictPackage);
        var relationships = new Dictionary<string, Relationship>(StringComparer.Ordinal);
        foreach (var element in root.Elements(root.Name.Namespace + "Relationship"))
        {
            SpreadsheetBudget.Require(relationships.Count < 1_000);
            string? id = (string?)element.Attribute("Id");
            string? type = (string?)element.Attribute("Type");
            string? target = (string?)element.Attribute("Target");
            if (id is null || type is null || target is null) throw WorkbookArchive.Invalid();
            int split = type.LastIndexOf('/');
            string? kind = split >= 0 && type[..split] is DocumentRelations or StrictDocumentRelations ? type[(split + 1)..] : null;
            if (!relationships.TryAdd(id, new Relationship(kind, target, (string?)element.Attribute("TargetMode")))) throw WorkbookArchive.Invalid();
        }
        return relationships;
    }

    private static string[] ReadStrings(XElement? root)
    {
        if (root is null) return [];
        var result = new List<string>();
        int textBytes = 0;
        foreach (var item in root.Elements(root.Name.Namespace + "si"))
        {
            SpreadsheetBudget.Require(result.Count < SpreadsheetBudget.MaxCells);
            string value = ReadRichText(item);
            textBytes += Encoding.UTF8.GetByteCount(value);
            SpreadsheetBudget.Require(textBytes <= SpreadsheetBudget.MaxTextBytes);
            result.Add(value);
        }
        return result.ToArray();
    }

    private static Sheet ReadSheet(XElement root, string name, string[] shared, WorkbookDates dates, SpreadsheetBudget budget)
    {
        XNamespace ns = root.Name.Namespace;
        var data = root.Element(ns + "sheetData");
        var rows = new SortedDictionary<int, string[]>();
        int rowNumber = 0;
        int columns = 0;
        bool hasData = false;
        bool formulas = false;
        foreach (var row in data?.Elements(ns + "row") ?? [])
        {
            rowNumber = row.Attribute("r") is { } rowReference ? ParseRow(rowReference.Value) : rowNumber + 1;
            var cells = new SortedDictionary<int, string>();
            int column = 0;
            foreach (var cell in row.Elements(ns + "c"))
            {
                column = cell.Attribute("r") is { } reference ? ParseColumn(reference.Value, rowNumber) : column + 1;
                SpreadsheetBudget.Require(rowNumber <= SpreadsheetBudget.MaxRows && column <= SpreadsheetBudget.MaxColumns);
                bool formula = cell.Element(ns + "f") is not null;
                formulas |= formula;
                string value = CellValue(cell, formula, shared, dates);
                budget.Add(value);
                hasData |= formula || value.Length != 0;
                if (!cells.TryAdd(column, value)) throw WorkbookArchive.Invalid();
            }
            if (cells.Count == 0) continue;
            var values = new string[cells.Keys.Last()];
            Array.Fill(values, string.Empty);
            foreach (var cell in cells) values[cell.Key - 1] = cell.Value;
            if (!rows.TryAdd(rowNumber, values)) throw WorkbookArchive.Invalid();
            columns = Math.Max(columns, values.Length);
        }
        if (!hasData) return new Sheet(name, [], [], 0, formulas);
        int count = rows.Keys.Last();
        var allRows = Enumerable.Range(1, count).Select(index => rows.GetValueOrDefault(index) ?? []).ToArray();
        return new Sheet(name, allRows, Enumerable.Range(1, count).ToArray(), columns, formulas);
    }

    private static string CellValue(XElement cell, bool formula, string[] shared, WorkbookDates dates)
    {
        XNamespace ns = cell.Name.Namespace;
        string cache = cell.Element(ns + "v")?.Value ?? string.Empty;
        SpreadsheetBudget.Require(cache.Length <= SpreadsheetBudget.MaxCellLength * 7);
        if (formula && cache.Length == 0) return string.Empty;
        return ((string?)cell.Attribute("t") ?? "n") switch
        {
            "s" => int.TryParse(cache, NumberStyles.Integer, CultureInfo.InvariantCulture, out int index) && index >= 0 && index < shared.Length
                ? shared[index] : throw WorkbookArchive.Invalid(),
            "inlineStr" => ReadRichText(cell.Element(ns + "is")),
            "str" => DecodeEscapes(cache),
            "b" when cache is "1" or "true" => "TRUE",
            "b" when cache is "0" or "false" => "FALSE",
            "n" => dates.Render(cache, int.TryParse((string?)cell.Attribute("s"), out int style) ? style : 0),
            _ => cache
        };
    }

    private static string ReadRichText(XElement? item)
    {
        if (item is null) return string.Empty;
        XNamespace ns = item.Name.Namespace;
        var value = new StringBuilder();
        foreach (var child in item.Elements())
        {
            if (child.Name == ns + "t") value.Append(child.Value);
            else if (child.Name == ns + "r") value.Append(child.Element(ns + "t")?.Value);
            SpreadsheetBudget.Require(value.Length <= SpreadsheetBudget.MaxCellLength * 7);
        }
        string decoded = DecodeEscapes(value.ToString());
        SpreadsheetBudget.Require(decoded.Length <= SpreadsheetBudget.MaxCellLength);
        return decoded;
    }

    private static string DecodeEscapes(string text)
    {
        if (!text.Contains("_x", StringComparison.Ordinal)) return text;
        var result = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            if (i + 6 < text.Length && text[i] == '_' && text[i + 1] == 'x' && text[i + 6] == '_' &&
                ushort.TryParse(text.AsSpan(i + 2, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out ushort unit))
            {
                result.Append((char)unit);
                i += 6;
            }
            else result.Append(text[i]);
        }
        return Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(result.ToString()));
    }

    private static int ParseRow(string value) => int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out int row) && row is >= 1 and <= 1_048_576
        ? row : throw WorkbookArchive.Invalid();

    private static int ParseColumn(string reference, int row)
    {
        int length = 0;
        int column = 0;
        while (length < reference.Length && reference[length] is >= 'A' and <= 'Z' && length < 3)
            column = column * 26 + reference[length++] - 'A' + 1;
        if (column == 0 || ParseRow(reference[length..]) != row) throw WorkbookArchive.Invalid();
        return column;
    }

    private sealed record Relationship(string? Kind, string Target, string? Mode)
    {
        public string Resolve(string? owner)
        {
            string target = Uri.UnescapeDataString(Target);
            if (Mode is not (null or "Internal") || target.Length == 0 || target.StartsWith("//", StringComparison.Ordinal) ||
                target.IndexOfAny([':', '\\', '?', '#', '\0']) >= 0) throw WorkbookArchive.Invalid();
            var parts = new List<string>();
            if (!target.StartsWith('/') && owner is not null) parts.AddRange(owner.Split('/').SkipLast(1));
            foreach (string component in target.Split('/', StringSplitOptions.RemoveEmptyEntries))
            {
                if (component == ".") continue;
                if (component == "..")
                {
                    if (parts.Count == 0) throw WorkbookArchive.Invalid();
                    parts.RemoveAt(parts.Count - 1);
                }
                else parts.Add(component);
            }
            if (parts.Count == 0) throw WorkbookArchive.Invalid();
            return string.Join('/', parts);
        }
    }
}
