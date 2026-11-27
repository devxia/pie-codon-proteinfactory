using System.IO.Compression;
using System.Xml;
using System.Xml.Linq;

namespace CodonProteinFactory.SequenceIO;

internal sealed class WorkbookArchive : IDisposable
{
    private const long MaximumExpandedBytes = 40 * 1024 * 1024;
    private readonly ZipArchive archive;
    private readonly Dictionary<string, ZipArchiveEntry> members = new(StringComparer.Ordinal);

    public WorkbookArchive(byte[] bytes)
    {
        archive = new ZipArchive(new MemoryStream(bytes, writable: false));
        try
        {
            SpreadsheetBudget.Require(archive.Entries.Count <= 1_000);
            long total = 0;
            foreach (var entry in archive.Entries)
            {
                SpreadsheetBudget.Require(entry.Length <= MaximumExpandedBytes - total);
                total += entry.Length;
                string name = entry.FullName.TrimEnd('/');
                if (name.IndexOfAny(['\\', ':', '?', '#', '\0']) >= 0 ||
                    name.Split('/').Any(part => part is "" or "." or "..") ||
                    ((entry.ExternalAttributes >> 16) & 0xf000) == 0xa000 || !members.TryAdd(name, entry))
                    throw Invalid();
            }
        }
        catch { archive.Dispose(); throw; }
    }

    public XElement ReadXml(string path, string root, params string[] namespaces)
    {
        if (!members.TryGetValue(path, out var entry)) throw Invalid();
        byte[] data = new byte[(int)entry.Length];
        using (var source = entry.Open())
        {
            source.ReadExactly(data);
            if (source.ReadByte() >= 0) throw Invalid();
        }
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit,
            XmlResolver = null,
            MaxCharactersInDocument = MaximumExpandedBytes,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true
        };
        using var stream = new MemoryStream(data, writable: false);
        using (var guard = XmlReader.Create(stream, settings))
        {
            int elements = 0;
            while (guard.Read())
                if (guard.NodeType == XmlNodeType.Element)
                    SpreadsheetBudget.Require(guard.Depth < 64 && ++elements <= 1_000_000);
        }
        stream.Position = 0;
        using var reader = XmlReader.Create(stream, settings);
        var document = XDocument.Load(reader, LoadOptions.PreserveWhitespace);
        var element = document.Root;
        if (element is null || element.Name.LocalName != root || !namespaces.Contains(element.Name.NamespaceName)) throw Invalid();
        return element;
    }

    public void Dispose() => archive.Dispose();

    internal static ImportException Invalid(Exception? error = null) =>
        new(ImportErrorCode.InvalidWorkbook, "Invalid XLSX workbook or unsafe workbook content.", inner: error);
}
