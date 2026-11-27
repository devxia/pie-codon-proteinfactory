import Foundation

struct XLSXSpreadsheet {
    private static let relationshipNamespaces = [
        "http://schemas.openxmlformats.org/package/2006/relationships",
        "http://purl.oclc.org/ooxml/package/relationships",
    ]
    private static let relationshipPrefixes = [
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/",
        "http://purl.oclc.org/ooxml/officeDocument/relationships/",
    ]

    static func read(_ data: Data) throws -> [SpreadsheetSheet] {
        do {
            return try readWorkbook(WorkbookArchive(data))
        } catch let error as SpreadsheetReadError {
            throw error
        } catch {
            throw SpreadsheetReadError.invalidWorkbook
        }
    }

    private static func readWorkbook(_ archive: WorkbookArchive) throws -> [SpreadsheetSheet] {
        let rootRelationships = try relationships(in: archive, part: nil)
        guard let document = rootRelationships.values.first(where: { $0.kind == "officeDocument" }) else {
            throw SpreadsheetReadError.invalidWorkbook
        }
        let workbookPath = try document.part(relativeTo: nil)
        let workbookRelationships = try relationships(in: archive, part: workbookPath)
        var sheetReferences: [(name: String, relationshipID: String)] = []
        var uses1904Dates = false
        try WorkbookXML.read(archive.read(workbookPath), root: "workbook", start: { path, attributes in
            switch path {
            case ["workbook", "workbookPr"]:
                uses1904Dates = attributes["date1904"] == "1" || attributes["date1904"] == "true"
            case ["workbook", "sheets", "sheet"]:
                guard sheetReferences.count < SpreadsheetBudget.maximumSheets else {
                    throw SpreadsheetReadError.importLimitExceeded
                }
                let relationshipIDs = attributes.filter { $0.key.hasSuffix(":id") }
                guard let name = attributes["name"], !name.isEmpty, relationshipIDs.count == 1,
                      let id = relationshipIDs.first?.value else {
                    throw SpreadsheetReadError.invalidWorkbook
                }
                sheetReferences.append((name, id))
            default: break
            }
        })

        var sharedStrings: [String] = []
        if let relationship = workbookRelationships.values.first(where: { $0.kind == "sharedStrings" }) {
            let path = try relationship.part(relativeTo: workbookPath)
            sharedStrings = try readSharedStrings(archive.read(path))
        }
        var dates = WorkbookDates(uses1904Dates: uses1904Dates)
        if let relationship = workbookRelationships.values.first(where: { $0.kind == "styles" }) {
            let path = try relationship.part(relativeTo: workbookPath)
            try dates.readStyles(archive.read(path))
        }

        var sheets: [SpreadsheetSheet] = []
        var worksheetParts: Set<String> = []
        var budget = SpreadsheetBudget()
        for sheet in sheetReferences {
            guard let relationship = workbookRelationships[sheet.relationshipID] else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            guard relationship.kind == "worksheet" else { continue }
            let path = try relationship.part(relativeTo: workbookPath)
            guard worksheetParts.insert(path).inserted else { throw SpreadsheetReadError.invalidWorkbook }
            let reader = WorksheetReader(sharedStrings: sharedStrings, dates: dates, budget: budget)
            sheets.append(try reader.read(archive.read(path), name: sheet.name))
            budget = reader.budget
        }
        return sheets
    }

    private static func relationships(in archive: WorkbookArchive, part: String?) throws -> [String: Relationship] {
        let path: String
        if let part {
            var components = part.split(separator: "/").map(String.init)
            let filename = components.removeLast()
            path = (components + ["_rels", filename + ".rels"]).joined(separator: "/")
        } else {
            path = "_rels/.rels"
        }
        var relationships: [String: Relationship] = [:]
        var uniqueKinds: Set<String> = []
        try WorkbookXML.read(archive.read(path), root: "Relationships", namespaces: relationshipNamespaces, start: { elements, attributes in
            guard elements == ["Relationships", "Relationship"] else { return }
            guard let id = attributes["Id"], let type = attributes["Type"], let target = attributes["Target"],
                  relationships[id] == nil else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            let kind = relationshipPrefixes.first(where: { type.hasPrefix($0) }).map { String(type.dropFirst($0.count)) }
            if let kind, ["officeDocument", "styles", "sharedStrings"].contains(kind),
               !uniqueKinds.insert(kind).inserted {
                throw SpreadsheetReadError.invalidWorkbook
            }
            relationships[id] = Relationship(kind: kind, target: target, mode: attributes["TargetMode"])
            guard relationships.count <= 1_000 else { throw SpreadsheetReadError.importLimitExceeded }
        })
        return relationships
    }

    private static func readSharedStrings(_ data: Data) throws -> [String] {
        var strings: [String] = []
        var accumulator = WorkbookText()
        try WorkbookXML.read(data, root: "sst", start: { path, _ in
            if path == ["sst", "si"] { accumulator = WorkbookText() }
        }, text: { path, text in
            if path == ["sst", "si", "t"] || path == ["sst", "si", "r", "t"] {
                try accumulator.append(text)
            }
        }, end: { path in
            if path == ["sst", "si"] {
                guard strings.count < SpreadsheetBudget.maximumCells else {
                    throw SpreadsheetReadError.importLimitExceeded
                }
                strings.append(try accumulator.decoded())
            }
        })
        return strings
    }

    private struct Relationship {
        let kind: String?
        let target: String
        let mode: String?

        func part(relativeTo source: String?) throws -> String {
            guard mode == nil || mode == "Internal", let path = target.removingPercentEncoding,
                  !path.isEmpty, !path.contains(where: { ":\\?#\0".contains($0) }), !path.hasPrefix("//") else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            var components = path.hasPrefix("/") ? [] : source?.split(separator: "/").dropLast().map(String.init) ?? []
            for segment in path.split(separator: "/") {
                switch segment {
                case ".": continue
                case "..":
                    guard !components.isEmpty else { throw SpreadsheetReadError.invalidWorkbook }
                    components.removeLast()
                default: components.append(String(segment))
                }
            }
            guard !components.isEmpty else { throw SpreadsheetReadError.invalidWorkbook }
            return components.joined(separator: "/")
        }
    }
}

private final class WorksheetReader {
    private static let rowPath = ["worksheet", "sheetData", "row"]
    private static let cellPath = rowPath + ["c"]

    private let sharedStrings: [String]
    private let dates: WorkbookDates
    private(set) var budget: SpreadsheetBudget
    private var rows: [[String]] = []
    private var columnCount = 0
    private var containsFormulas = false
    private var hasData = false
    private var seenRows: Set<Int> = []
    private var seenColumns: Set<Int> = []
    private var row: [String] = []
    private var rowNumber = 0
    private var columnNumber = 0
    private var cell = Cell()

    init(sharedStrings: [String], dates: WorkbookDates, budget: SpreadsheetBudget) {
        self.sharedStrings = sharedStrings
        self.dates = dates
        self.budget = budget
    }

    func read(_ data: Data, name: String) throws -> SpreadsheetSheet {
        try WorkbookXML.read(data, root: "worksheet", start: start, text: appendText, end: end)
        let dataRows = hasData ? rows : []
        return SpreadsheetSheet(
            name: name, rows: dataRows, sourceRows: dataRows.indices.map { $0 + 1 },
            columnCount: hasData ? columnCount : 0, containsFormulas: containsFormulas
        )
    }

    private func start(_ path: [String], _ attributes: [String: String]) throws {
        switch path {
        case Self.rowPath:
            if let reference = attributes["r"] {
                guard let parsed = Int(reference), (1...1_048_576).contains(parsed) else {
                    throw SpreadsheetReadError.invalidWorkbook
                }
                rowNumber = parsed
            } else {
                rowNumber += 1
            }
            row.removeAll(keepingCapacity: true)
            seenColumns.removeAll(keepingCapacity: true)
            columnNumber = 0
        case Self.cellPath:
            if let reference = attributes["r"] {
                let position = try Self.position(reference)
                guard position.row == rowNumber else { throw SpreadsheetReadError.invalidWorkbook }
                columnNumber = position.column
            } else {
                columnNumber += 1
            }
            guard rowNumber <= SpreadsheetBudget.maximumRows, columnNumber <= SpreadsheetBudget.maximumColumns else {
                throw SpreadsheetReadError.importLimitExceeded
            }
            guard seenColumns.insert(columnNumber).inserted else { throw SpreadsheetReadError.invalidWorkbook }
            cell = Cell(type: attributes["t"] ?? "n", style: attributes["s"].flatMap(Int.init) ?? 0)
        case Self.cellPath + ["f"]:
            containsFormulas = true
            cell.hasFormula = true
        default: break
        }
    }

    private func appendText(_ path: [String], _ text: String) throws {
        switch path {
        case Self.cellPath + ["v"]:
            try cell.cached.append(text)
        case Self.cellPath + ["is", "t"], Self.cellPath + ["is", "r", "t"]:
            try cell.inline.append(text)
        default: break
        }
    }

    private func end(_ path: [String]) throws {
        switch path {
        case Self.cellPath:
            let value = try cellValue()
            try SpreadsheetBudget.validateText(value)
            try budget.add(value)
            hasData = hasData || cell.hasFormula || !value.isEmpty
            if row.count < columnNumber { row.append(contentsOf: repeatElement("", count: columnNumber - row.count)) }
            row[columnNumber - 1] = value
        case Self.rowPath:
            guard !row.isEmpty else { return }
            guard seenRows.insert(rowNumber).inserted else { throw SpreadsheetReadError.invalidWorkbook }
            if rows.count < rowNumber { rows.append(contentsOf: repeatElement([], count: rowNumber - rows.count)) }
            rows[rowNumber - 1] = row
            columnCount = max(columnCount, row.count)
        default: break
        }
    }

    private func cellValue() throws -> String {
        let cached = cell.cached.value
        if cell.hasFormula && cached.isEmpty { return "" }
        switch cell.type {
        case "s":
            guard let index = Int(cached), sharedStrings.indices.contains(index) else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            return sharedStrings[index]
        case "inlineStr": return try cell.inline.decoded()
        case "str": return try cell.cached.decoded()
        case "b":
            if cached == "1" || cached == "true" { return "TRUE" }
            if cached == "0" || cached == "false" { return "FALSE" }
            return cached
        case "n": return dates.render(cached, style: cell.style)
        default: return cached
        }
    }

    private static func position(_ reference: String) throws -> (row: Int, column: Int) {
        let bytes = reference.utf8
        let letters = bytes.prefix { (65...90).contains($0) }
        guard (1...3).contains(letters.count), let row = Int(reference.dropFirst(letters.count)),
              (1...1_048_576).contains(row) else {
            throw SpreadsheetReadError.invalidWorkbook
        }
        let column = letters.reduce(0) { $0 * 26 + Int($1) - 64 }
        return (row, column)
    }

    private struct Cell {
        var type = "n"
        var style = 0
        var cached = WorkbookText()
        var inline = WorkbookText()
        var hasFormula = false
    }
}
