import Foundation
import SequenceIO

public enum ProteinImportSource: Equatable, Sendable {
    case paste(line: Int)
    case fasta(line: Int)
    case spreadsheet(worksheetIndex: Int, worksheetName: String?, row: Int)

    public var sourceRow: Int {
        switch self {
        case .paste(let line), .fasta(let line), .spreadsheet(_, _, let line): line
        }
    }
}

public struct ProteinImportRecord: Equatable, Sendable {
    public let source: ProteinImportSource
    public let rawName: String?
    public let rawSequence: String?
}

public enum SpreadsheetColumnRole: Equatable, Sendable {
    case name, sequence
}

public struct SpreadsheetColumnMapping: Equatable, Sendable {
    /// Worksheet and column indices are zero-based.
    public let worksheetIndex: Int
    public let firstRowIsHeader: Bool
    public let nameColumn: Int
    public let sequenceColumn: Int

    public init(worksheetIndex: Int, firstRowIsHeader: Bool, nameColumn: Int, sequenceColumn: Int) {
        self.worksheetIndex = worksheetIndex
        self.firstRowIsHeader = firstRowIsHeader
        self.nameColumn = nameColumn
        self.sequenceColumn = sequenceColumn
    }
}

public enum SpreadsheetMappingError: Error, Equatable, Sendable {
    case worksheetOutOfBounds(index: Int, sheetCount: Int)
    case emptyWorksheet(index: Int)
    case columnsMustDiffer
    case columnOutOfBounds(role: SpreadsheetColumnRole, index: Int, columnCount: Int)
    case noDataRows(worksheetIndex: Int)
}

public enum ProteinImport {
    public static func read(pastedText: String, defaultName: String? = nil) throws -> [ProteinImportRecord] {
        try FASTAReader.readLocated(pastedText, defaultName: defaultName).map {
            fastaRecord($0, source: .paste(line: $0.sourceLine))
        }
    }

    public static func read(fastaData: Data, defaultName: String? = nil) throws -> [ProteinImportRecord] {
        try FASTAReader.readLocated(fastaData, defaultName: defaultName).map {
            fastaRecord($0, source: .fasta(line: $0.sourceLine))
        }
    }

    public static func read(
        spreadsheet: Spreadsheet, mapping: SpreadsheetColumnMapping
    ) throws -> [ProteinImportRecord] {
        let index = mapping.worksheetIndex
        guard spreadsheet.sheets.indices.contains(index) else {
            throw SpreadsheetMappingError.worksheetOutOfBounds(index: index, sheetCount: spreadsheet.sheets.count)
        }
        let sheet = spreadsheet.sheets[index]
        guard !sheet.rows.isEmpty else { throw SpreadsheetMappingError.emptyWorksheet(index: index) }
        guard mapping.nameColumn != mapping.sequenceColumn else { throw SpreadsheetMappingError.columnsMustDiffer }
        let columns = 0..<sheet.columnCount
        for (role, column) in [(SpreadsheetColumnRole.name, mapping.nameColumn), (.sequence, mapping.sequenceColumn)] {
            guard columns.contains(column) else {
                throw SpreadsheetMappingError.columnOutOfBounds(role: role, index: column, columnCount: sheet.columnCount)
            }
        }

        let rows = zip(sheet.rows, sheet.sourceRows).dropFirst(mapping.firstRowIsHeader ? 1 : 0)
        var records: [ProteinImportRecord] = []
        for (row, sourceRow) in rows where !row.allSatisfy(isBlank) {
            records.append(ProteinImportRecord(
                source: .spreadsheet(worksheetIndex: index, worksheetName: sheet.name, row: sourceRow),
                rawName: row.indices.contains(mapping.nameColumn) ? row[mapping.nameColumn] : nil,
                rawSequence: row.indices.contains(mapping.sequenceColumn) ? row[mapping.sequenceColumn] : nil
            ))
        }
        guard !records.isEmpty else { throw SpreadsheetMappingError.noDataRows(worksheetIndex: index) }
        return records
    }

    private static func fastaRecord(_ located: LocatedFASTARecord, source: ProteinImportSource) -> ProteinImportRecord {
        ProteinImportRecord(source: source, rawName: located.record.name, rawSequence: located.record.originalSequence)
    }

    private static func isBlank(_ cell: String) -> Bool {
        cell.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0 == "\u{FEFF}" }
    }
}
