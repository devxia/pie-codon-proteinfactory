import Foundation
import SequenceIO

struct SpreadsheetInspection: Sendable {
    let id = UUID()
    let filename: String
    let format: SpreadsheetFormat
    let byteCount: Int
    let spreadsheet: Spreadsheet

    init(url: URL) throws {
        filename = url.lastPathComponent
        format = try SpreadsheetFormat(fileExtension: url.pathExtension)
        let data = try LocalFile.read(at: url, maximumBytes: SpreadsheetFormat.maximumFileBytes, validateSize: SpreadsheetFormat.validateFileSize)
        byteCount = data.count
        spreadsheet = try SpreadsheetReader.read(data, format: format)
    }
}
