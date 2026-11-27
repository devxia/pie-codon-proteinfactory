public enum SpreadsheetFormat: String, Sendable {
    case xlsx
    case csv
    case tsv

    public static let maximumFileBytes = 5 * 1_024 * 1_024

    public init(fileExtension: String) throws {
        let normalizedExtension = fileExtension.lowercased()
        if normalizedExtension == "xls" {
            throw SpreadsheetInputError.legacyWorkbook
        }
        guard let format = Self(rawValue: normalizedExtension) else {
            throw SpreadsheetInputError.unsupportedExtension(fileExtension)
        }
        self = format
    }

    public static func validateFileSize(_ bytes: Int) throws {
        guard bytes > 0 else { throw SpreadsheetInputError.emptyFile }
        guard bytes <= maximumFileBytes else {
            throw SpreadsheetInputError.fileTooLarge(limit: maximumFileBytes)
        }
    }
}

public enum SpreadsheetInputError: Error, Equatable, Sendable {
    case legacyWorkbook
    case unsupportedExtension(String)
    case emptyFile
    case fileTooLarge(limit: Int)
}
