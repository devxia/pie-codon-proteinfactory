import Foundation

public struct Spreadsheet: Sendable {
    public let sheets: [SpreadsheetSheet]
}

public struct SpreadsheetSheet: Sendable {
    /// Delimited files have no worksheet name.
    public let name: String?
    /// Missing rows are empty arrays. Missing cells preceding populated cells are empty strings.
    public let rows: [[String]]
    /// One-based physical start line or worksheet row for each entry of `rows`.
    public let sourceRows: [Int]
    public let columnCount: Int
    public let containsFormulas: Bool
}

public enum SpreadsheetReadError: Error, Equatable, Sendable {
    case invalidEncoding
    case malformedDelimitedText
    case invalidWorkbook
    case emptyData
    case importLimitExceeded
}

public enum SpreadsheetReader {
    public static func read(_ data: Data, format: SpreadsheetFormat) throws -> Spreadsheet {
        try SpreadsheetFormat.validateFileSize(data.count)
        let sheets: [SpreadsheetSheet]
        switch format {
        case .csv, .tsv:
            sheets = [try DelimitedSpreadsheet.read(data, format: format)]
        case .xlsx:
            sheets = try XLSXSpreadsheet.read(data)
        }
        guard sheets.contains(where: { !$0.rows.isEmpty }) else {
            throw SpreadsheetReadError.emptyData
        }
        return Spreadsheet(sheets: sheets)
    }
}

struct SpreadsheetBudget {
    static let maximumSheets = 20
    static let maximumRows = 2_000
    static let maximumColumns = 100
    static let maximumCells = 100_000
    static let maximumCellCharacters = 32_767
    static let maximumTextBytes = 8 * 1_024 * 1_024

    private var cells = 0
    private var textBytes = 0

    mutating func add(_ value: String) throws {
        cells += 1
        textBytes += value.utf8.count
        guard cells <= Self.maximumCells, textBytes <= Self.maximumTextBytes else {
            throw SpreadsheetReadError.importLimitExceeded
        }
    }

    static func validateText(_ value: String) throws {
        guard value.utf16.count <= maximumCellCharacters else {
            throw SpreadsheetReadError.importLimitExceeded
        }
    }
}
