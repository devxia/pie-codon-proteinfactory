import CoreXLSX
import Foundation
import Testing
import ZIPFoundation

struct XLSXCompatibilityTests {
    @Test func formulaCachesAreSeparateFromFormulaSource() throws {
        let (_, cells) = try workbook(named: "workbook-1900")
        let numericCache = try #require(cells["D1"])
        #expect(numericCache.formula?.value == "2+3")
        #expect(numericCache.value == "5")

        let noCache = try #require(cells["F1"])
        #expect(noCache.formula?.value == "1+1")
        #expect(noCache.value?.isEmpty ?? true)

        let textCache = try #require(cells["L1"])
        #expect(textCache.type == .string)
        #expect(textCache.value == "north")
    }

    @Test func sparseCellCoordinatesAndSheetNameArePreserved() throws {
        let (file, cells) = try workbook(named: "workbook-1900")
        let workbooks = try file.parseWorkbooks()
        let workbook = try #require(workbooks.first)
        let sheets = try file.parseWorksheetPathsAndNames(workbook: workbook)
        let sheet = try #require(sheets.first)
        #expect(sheet.name == "样本表")
        #expect(cells.count == 14)
        #expect(cells["B1"] == nil)
        #expect(cells["A9"] == nil)
        #expect(cells["C5"]?.inlineString?.text == "  样本   B  ")
        let parsedStrings = try file.parseSharedStrings()
        let sharedStrings = try #require(parsedStrings)
        #expect(cells["A1"]?.stringValue(sharedStrings) == "标签")
        #expect(cells["B9"]?.stringValue(sharedStrings) == "标签")
    }

    @Test func formulaLikeLabelsAreStoredAsLiteralText() throws {
        let (_, cells) = try workbook(named: "workbook-1900")
        for (offset, label) in ["=1+1", "+label", "-label", "@label", "\tlabel", "\rlabel"].enumerated() {
            let coordinate = "M\(offset + 1)"
            let cell = try #require(cells[coordinate])
            #expect(cell.type == .inlineStr, "\(coordinate)")
            #expect(cell.inlineString?.text == label, "\(coordinate)")
            #expect(cell.formula == nil, "\(coordinate)")
        }
    }

    @Test func defaultFillPreventsStyleDecoding() throws {
        let (file, _) = try workbook(named: "workbook-1900")
        do {
            _ = try file.parseStyles()
            Issue.record("Default fill now decodes. Recheck the CoreXLSX compatibility decision.")
        } catch DecodingError.keyNotFound(let key, let context) {
            #expect(key.stringValue == "patternType")
            #expect(context.codingPath.contains { $0.stringValue == "patternFill" })
        }
    }

    @Test func dateHelperNeedsStyleAndWorkbookDateSystem() throws {
        let (_, cells) = try workbook(named: "workbook-1900")
        let date = try #require(cells["H1"])
        let number = try #require(cells["K1"])
        #expect(date.value == number.value)
        #expect(date.styleIndex == 1)
        #expect(number.styleIndex == nil)
        let interpretedDate = try #require(date.dateValue)
        #expect(interpretedDate == number.dateValue)

        let (_, cells1904) = try workbook(named: "workbook-1904")
        let date1904 = try #require(cells1904["C3"])
        let serial = try #require(date.value.flatMap(Double.init))
        let serial1904 = try #require(date1904.value.flatMap(Double.init))
        #expect(abs((serial - serial1904) - 1_462) < 0.000_001)
        let workbookXML = try xmlMember("xl/workbook.xml", in: "workbook-1904")
        #expect(workbookXML.contains("date1904=\"1\""))
        #expect(interpretedDate != date1904.dateValue)
    }

    private func workbook(named name: String) throws -> (XLSXFile, [String: Cell]) {
        let file = try XLSXFile(data: Data(contentsOf: fixture(named: name)))
        let paths = try file.parseWorksheetPaths()
        let path = try #require(paths.first)
        let sheet = try file.parseWorksheet(at: path)
        let rows = try #require(sheet.data?.rows)
        let cells = rows.flatMap(\.cells)
        return (file, Dictionary(uniqueKeysWithValues: cells.map { ($0.reference.description, $0) }))
    }

    private func xmlMember(_ member: String, in name: String) throws -> String {
        let archive = try Archive(url: fixture(named: name), accessMode: .read)
        let entry = try #require(archive[member])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return try #require(String(data: data, encoding: .utf8))
    }

    private func fixture(named name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures"))
    }
}
