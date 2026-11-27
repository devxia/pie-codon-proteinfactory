import Foundation
import ProteinApplication
import ProteinDomain
import SequenceIO
import Testing

struct ProteinImportTests {
    @Test func csvCollectsEveryRowIssueAndRetainsValidRowsInSourceOrder() throws {
        let csv = "Name,Sequence,Notes\r\n  same  ,\"a\r\nc\",keep\r\n,a-x,bad\r\nlone\r\nsame,k*,keep\r\nonly,\r\n,,"
        let book = try SpreadsheetReader.read(Data(csv.utf8), format: .csv)
        let records = try ProteinImport.read(spreadsheet: book, mapping: mapping())
        let result = try ProteinImport.validate(records)

        #expect(result.records.map(\.position) == [1, 2, 3, 4, 5])
        #expect(result.records.map(\.record.source.sourceRow) == [2, 4, 5, 6, 7])
        #expect(result.records[0].record.rawName == "  same  ")
        #expect(result.records[0].record.rawSequence == "a\r\nc")
        #expect(result.records.map(\.issues) == [
            [], [.input(.invalidName), .input(.sequence(.invalidResidue(position: 2)))],
            [.missingCell(.sequence)], [], [.input(.sequence(.empty))],
        ])
        let validRows = result.records.filter { $0.issues.isEmpty }
        #expect(validRows.map(\.name) == ["same", "same"])
        #expect(validRows.map(\.originalSequence?.value) == ["AC", "K*"])
        #expect(!result.isValid)
        #expect(throws: ProteinImportPreparationError.validationFailed) {
            try ProteinImport.prepare(name: "Mixed input", validation: result)
        }
    }

    @Test func tsvMappingKeepsPhysicalRowsAndDistinguishesMissingAndEmptyName() throws {
        let tsv = "Seq\tName\tNotes\r\n\"a\nb\"\tfirst\tkeep\r\nQ\r\nW\t\tkeep\r\n\t\t  \r\nK\tlast"
        let book = try SpreadsheetReader.read(Data(tsv.utf8), format: .tsv)
        let records = try ProteinImport.read(spreadsheet: book, mapping: mapping(name: 1, sequence: 0))
        let result = try ProteinImport.validate(records)

        #expect(result.records.map(\.record.source.sourceRow) == [2, 4, 5, 7])
        #expect(result.records.map(\.issues) == [
            [.input(.sequence(.invalidResidue(position: 2)))], [.missingCell(.name)], [.input(.invalidName)], [],
        ])
        #expect(result.records[1].originalSequence?.value == "Q")
        #expect(result.records[3].originalSequence?.value == "K")
    }

    @Test func xlsxUsesSelectedWorksheetHeaderAndColumnOrder() throws {
        let url = try #require(Bundle.module.url(forResource: "sparse-import", withExtension: "xlsx", subdirectory: "Fixtures"))
        let book = try SpreadsheetReader.read(Data(contentsOf: url), format: .xlsx)
        let first = try ProteinImport.read(spreadsheet: book, mapping: mapping())
        #expect(first.map(\.source) == [.spreadsheet(worksheetIndex: 0, worksheetName: "Names first", row: 3)])
        #expect(first.map(\.rawName) == ["single"])

        let secondMapping = mapping(worksheet: 1, name: 1, sequence: 0)
        let second = try ProteinImport.read(spreadsheet: book, mapping: secondMapping)
        let validation = try ProteinImport.validate(second)
        let preview = try ProteinImport.prepare(name: "Second sheet", validation: validation)
        #expect(preview.records.map(\.source) == [
            .spreadsheet(worksheetIndex: 1, worksheetName: "Sequences first", row: 4),
            .spreadsheet(worksheetIndex: 1, worksheetName: "Sequences first", row: 7),
        ])
        #expect(preview.records.map(\.name) == ["repeat", "repeat"])
        #expect(preview.records.map(\.originalSequence.value) == ["AQ", "W*"])

        let withHeader = try ProteinImport.read(spreadsheet: book, mapping: mapping(worksheet: 1, header: false, name: 1, sequence: 0))
        #expect(withHeader.map(\.source.sourceRow) == [1, 4, 7])
        #expect(withHeader.map(\.rawName) == ["Name", "repeat", "repeat"])
        #expect(!(try ProteinImport.validate(withHeader)).isValid)
        #expect(throws: SpreadsheetMappingError.emptyWorksheet(index: 2)) {
            try ProteinImport.read(spreadsheet: book, mapping: mapping(worksheet: 2))
        }
    }

    @Test func mappingRejectsOutOfBoundsDuplicateAndNoDataSelections() throws {
        let book = try SpreadsheetReader.read(Data("Name,Sequence\n ,  \n".utf8), format: .csv)
        for (selection, error) in [
            (mapping(worksheet: -1), SpreadsheetMappingError.worksheetOutOfBounds(index: -1, sheetCount: 1)),
            (mapping(worksheet: 1), .worksheetOutOfBounds(index: 1, sheetCount: 1)),
            (mapping(name: 1), .columnsMustDiffer),
            (mapping(name: -1), .columnOutOfBounds(role: .name, index: -1, columnCount: 2)),
            (mapping(sequence: 2), .columnOutOfBounds(role: .sequence, index: 2, columnCount: 2)),
            (mapping(), .noDataRows(worksheetIndex: 0)),
        ] {
            #expect(throws: error) { try ProteinImport.read(spreadsheet: book, mapping: selection) }
        }
    }

    @Test func plainPasteUsesDefaultNameAndFASTADataKeepsRecordLocations() throws {
        let text = "\u{FEFF}\r\n\r\n m k*\r\n"
        let paste = try ProteinImport.read(pastedText: text)
        #expect(paste.map(\.rawName) == ["Protein 1"])
        #expect(paste.map(\.rawSequence) == ["mk*"])
        #expect(paste.map(\.source) == [.paste(line: 3)])
        #expect(try ProteinImport.read(pastedText: text, defaultName: " My sample ").map(\.rawName) == ["My sample"])
        #expect(try ProteinImport.read(fastaData: Data(text.utf8), defaultName: "From file").map(\.rawName) == ["From file"])

        let fasta = Data("\u{FEFF}>one\r\nMk\r\n\r\n>one\r\nAc*\r\n".utf8)
        let records = try ProteinImport.read(fastaData: fasta)
        let validation = try ProteinImport.validate(records)
        let preview = try ProteinImport.prepare(name: "Local FASTA", validation: validation)
        #expect(preview.records.map(\.name) == ["one", "one"])
        #expect(preview.records.map(\.source) == [.fasta(line: 1), .fasta(line: 4)])
        #expect(preview.records.map(\.rawSequence) == ["Mk", "Ac*"])
        #expect(preview.records.map(\.submittedSequence.value) == ["MK", "AC*"])
    }

    @Test func textAndFASTAReportParseErrorsOrEveryAvailableRecordError() throws {
        #expect(throws: FASTAReadError.invalidUTF8) { try ProteinImport.read(fastaData: Data([0xff])) }
        #expect(throws: FASTAReadError.emptyInput) { try ProteinImport.read(pastedText: " \t\r\n") }
        #expect(throws: FASTAReadError.emptySequence(record: 2, line: 4)) {
            try ProteinImport.read(pastedText: ">one\nM\n\n>empty\n")
        }
        let text = ">bad one\nA-X\n>good\ncd\n>bad two\nA*Q\n"
        let paste = try ProteinImport.read(pastedText: text)
        let fasta = try ProteinImport.read(fastaData: Data(text.utf8))
        let pasteResult = try ProteinImport.validate(paste)
        let fastaResult = try ProteinImport.validate(fasta)
        let expected: [[ProteinImportRecordIssue]] = [
            [.input(.sequence(.invalidResidue(position: 2)))], [], [.input(.sequence(.misplacedStop(position: 2)))],
        ]
        #expect(pasteResult.records.map(\.issues) == expected)
        #expect(fastaResult.records.map(\.issues) == expected)
        #expect(fastaResult.records.map(\.record.source.sourceRow) == [1, 3, 5])
        #expect(pasteResult.records[1].originalSequence?.value == "CD")
    }

    private func mapping(worksheet: Int = 0, header: Bool = true, name: Int = 0, sequence: Int = 1) -> SpreadsheetColumnMapping {
        .init(worksheetIndex: worksheet, firstRowIsHeader: header, nameColumn: name, sequenceColumn: sequence)
    }
}
