import Foundation
import SequenceIO
import Testing
import ZIPFoundation

struct SpreadsheetReaderTests {
    @Test func csvPreservesQuotedFieldsBlankRowsAndTrailingColumns() throws {
        let sample = "\u{FEFF}Name,Note,Empty\r\nNorth,\"quoted \"\"label\"\"\r\nnext line\",\r\n\r\nSouth,=1+1,"
        let sheet = try read(Data(sample.utf8), format: .csv)
        #expect(sheet.rows == [
            ["Name", "Note", "Empty"],
            ["North", "quoted \"label\"\r\nnext line", ""],
            [""],
            ["South", "=1+1", ""],
        ])
        #expect(sheet.sourceRows == [1, 2, 4, 5])
        #expect(sheet.columnCount == 3)
        #expect(!sheet.containsFormulas)
    }

    @Test func tsvPhysicalLinesCountEachNewlineStyleOnceInsideQuotedCells() throws {
        let text = "Name\tSequence\rAlpha\t\"m\r\nk\nQ\rT\"\rBeta\tW"
        let sheet = try read(Data(text.utf8), format: .tsv)
        #expect(sheet.sourceRows == [1, 2, 6])
        #expect(sheet.rows[1] == ["Alpha", "m\r\nk\nQ\rT"])
    }

    @Test func identifiesCommonDelimitersAndGB18030() throws {
        let semicolon = Data("Name;Count\nNorth;1,25\nSouth;2,75\n".utf8)
        #expect(try read(semicolon, format: .csv).rows.last == ["South", "2,75"])
        let tab = Data("Name\tNote\nNorth\ta,b;c\n".utf8)
        #expect(try read(tab, format: .csv).rows.last == ["North", "a,b;c"])
        #expect(try read(tab, format: .tsv).rows.last == ["North", "a,b;c"])
        let gb18030 = Data([0xB1, 0xEA, 0xC7, 0xA9, 9, 0x95, 0x32, 0x82, 0x36, 10])
        #expect(try read(gb18030, format: .tsv).rows == [["标签", "𠀀"]])
    }

    @Test func rejectsMissingDataMalformedFieldsAndInvalidEncoding() {
        #expect(throws: SpreadsheetReadError.emptyData) {
            try read(Data(",\n\"\",\n".utf8), format: .csv)
        }
        for source in ["Name,Note\nNorth,\"unfinished", "Name,Note\nNorth,\"closed\"suffix", "la\"bel,data"] {
            #expect(throws: SpreadsheetReadError.malformedDelimitedText) {
                try read(Data(source.utf8), format: .csv)
            }
        }
        for bytes: [UInt8] in [[0x81], [0x61, 0], [0xEF, 0xBB, 0xBF, 0xFF]] {
            #expect(throws: SpreadsheetReadError.invalidEncoding) {
                try read(Data(bytes), format: .tsv)
            }
        }
    }

    @Test func enforcesDelimitedLimits() throws {
        let maxCell = String(repeating: "x", count: 32_767)
        #expect(try read(Data(maxCell.utf8), format: .csv).rows == [[maxCell]])
        for data in [
            maxCell + "x",
            String(repeating: "x\n", count: 2_001),
            String(repeating: "x\t", count: 100) + "x",
            String(repeating: String(repeating: "x\t", count: 99) + "x\n", count: 1_001),
        ] {
            #expect(throws: SpreadsheetReadError.importLimitExceeded) {
                try read(Data(data.utf8), format: .tsv)
            }
        }
    }

    @Test func xlsxPreservesCoordinatesLiteralTextAndFormulaCaches() throws {
        let sheet = try read(fixture("workbook-1900"), format: .xlsx)
        #expect(sheet.name == "样本表")
        #expect(sheet.rows.count == 9)
        #expect(sheet.columnCount == 13)
        #expect(sheet.containsFormulas)
        #expect(sheet.rows[0] == ["标签", "", "", "5", "", "", "", "2024-02-29 12:30:00", "", "", "45351.52083333334", "north", "=1+1"])
        #expect(sheet.rows[4][2] == "  样本   B  ")
        #expect(sheet.rows[5][12] == "\rlabel")
        #expect(sheet.rows[6].isEmpty)
        #expect(sheet.rows[8] == ["", "标签"])

        let alternate = try read(fixture("workbook-1904"), format: .xlsx)
        #expect(alternate.rows == [[], [], ["", "", "2024-02-29 12:30:00"]])
        #expect(alternate.sourceRows == [1, 2, 3])
    }

    @Test func readsWorksheetOrderAndActualCellsWithoutFollowingExternalRelationships() throws {
        let cells = """
        <row r="2"><c r="B2" t="inlineStr"><is><r><t>North</t></r><r><t>_x000D_Desk</t></r><rPh><t>ignored</t></rPh></is></c><c r="D2" t="b"><v>1</v></c></row>
        """
        let book = try SpreadsheetReader.read(workbook(rows: cells, includeEmptySheet: true), format: .xlsx)
        #expect(book.sheets.map(\.name) == ["Inventory", "Empty"])
        #expect(book.sheets[0].rows == [[], ["", "North\rDesk", "", "TRUE"]])
        #expect(book.sheets[0].columnCount == 4)
        #expect(book.sheets[1].rows.isEmpty)
    }

    @Test func rejectsUnsupportedOrInvalidWorkbookParts() throws {
        let withDTD = try workbook(rows: "", worksheetPrefix: "<!DOCTYPE worksheet>")
        let duplicate = try workbook(rows: "", duplicateSheetPart: true)
        let corruptWorkbook = Data("Not a workbook".utf8)
        for data in [withDTD, duplicate, corruptWorkbook] {
            #expect(throws: SpreadsheetReadError.invalidWorkbook) {
                try read(data, format: .xlsx)
            }
        }
        #expect(throws: SpreadsheetReadError.emptyData) {
            try read(workbook(rows: ""), format: .xlsx)
        }
    }

    @Test func boundsActualCoordinatesAndExpandedSharedStringText() throws {
        let outOfRange = try workbook(rows: #"<row r="2001"><c r="A2001"><v>1</v></c></row>"#)
        let repetitions = (1...280).map { "<row r=\"\($0)\"><c r=\"A\($0)\" t=\"s\"><v>0</v></c></row>" }.joined()
        let sharedString = String(repeating: "x", count: 30_000)
        let expanded = try workbook(rows: repetitions, sharedString: sharedString)
        #expect(expanded.count < 20_000)
        for data in [outOfRange, expanded] {
            #expect(throws: SpreadsheetReadError.importLimitExceeded) {
                try read(data, format: .xlsx)
            }
        }
    }

    private func read(_ data: Data, format: SpreadsheetFormat) throws -> SpreadsheetSheet {
        try #require(SpreadsheetReader.read(data, format: format).sheets.first)
    }

    private func fixture(_ name: String) throws -> Data {
        let location = try #require(Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures"))
        return try Data(contentsOf: location)
    }

    private func workbook(
        rows: String, includeEmptySheet: Bool = false, worksheetPrefix: String = "",
        duplicateSheetPart: Bool = false, sharedString: String? = nil
    ) throws -> Data {
        let archive = try Archive(accessMode: .create)
        let spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let package = "http://schemas.openxmlformats.org/package/2006/relationships"
        let office = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func relationship(_ id: String, _ type: String, _ target: String) -> String {
            "<Relationship Id=\"\(id)\" Type=\"\(office)/\(type)\" Target=\"\(target)\"/>"
        }
        func add(_ path: String, _ xml: String) throws {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) {
                offset, count in
                data.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        try add("_rels/.rels", "<Relationships xmlns=\"\(package)\">\(relationship("root", "officeDocument", "book/main.xml"))</Relationships>")
        var sheets = #"<sheet name="Inventory" sheetId="1" r:id="inventory"/>"#
        var relationships = relationship("inventory", "worksheet", "data/first.xml")
        relationships += "<Relationship Id=\"external\" Type=\"\(office)/externalLinkPath\" Target=\"https://example.invalid/sheet.xlsx\" TargetMode=\"External\"/>"
        if includeEmptySheet {
            sheets += #"<sheet name="Empty" sheetId="2" r:id="empty"/>"#
            relationships += relationship("empty", "worksheet", "/book/data/empty.xml")
            try add("book/data/empty.xml", "<worksheet xmlns=\"\(spreadsheet)\"><sheetData/></worksheet>")
        }
        if let sharedString {
            relationships += relationship("strings", "sharedStrings", "strings.xml")
            try add("book/strings.xml", "<sst xmlns=\"\(spreadsheet)\"><si><t>\(sharedString)</t></si></sst>")
        }
        try add("book/main.xml", "<workbook xmlns=\"\(spreadsheet)\" xmlns:r=\"\(office)\"><sheets>\(sheets)</sheets></workbook>")
        try add("book/_rels/main.xml.rels", "<Relationships xmlns=\"\(package)\">\(relationships)</Relationships>")
        let sheet = "\(worksheetPrefix)<worksheet xmlns=\"\(spreadsheet)\"><dimension ref=\"A1:XFD1048576\"/><sheetData>\(rows)</sheetData></worksheet>"
        try add("book/data/first.xml", sheet)
        if duplicateSheetPart { try add("book/data/first.xml", sheet) }
        return try #require(archive.data)
    }
}
