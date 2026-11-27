import SequenceIO
import Testing

struct SpreadsheetFormatTests {
    @Test func supportedExtensionsAreCaseInsensitive() throws {
        #expect(try SpreadsheetFormat(fileExtension: "XLSX") == .xlsx)
        #expect(try SpreadsheetFormat(fileExtension: "Csv") == .csv)
        #expect(try SpreadsheetFormat(fileExtension: "tsv") == .tsv)
    }

    @Test func legacyAndUnsupportedExtensionsAreDistinguishable() {
        #expect(throws: SpreadsheetInputError.legacyWorkbook) {
            try SpreadsheetFormat(fileExtension: "XLS")
        }
        #expect(throws: SpreadsheetInputError.unsupportedExtension("xlsm")) {
            try SpreadsheetFormat(fileExtension: "xlsm")
        }
        #expect(throws: SpreadsheetInputError.unsupportedExtension("")) {
            try SpreadsheetFormat(fileExtension: "")
        }
    }

    @Test func fileSizeBounds() throws {
        #expect(SpreadsheetFormat.maximumFileBytes == 5_242_880)
        try SpreadsheetFormat.validateFileSize(1)
        try SpreadsheetFormat.validateFileSize(5_242_880)
        #expect(throws: SpreadsheetInputError.emptyFile) {
            try SpreadsheetFormat.validateFileSize(0)
        }
        #expect(throws: SpreadsheetInputError.fileTooLarge(limit: 5_242_880)) {
            try SpreadsheetFormat.validateFileSize(5_242_881)
        }
    }
}
