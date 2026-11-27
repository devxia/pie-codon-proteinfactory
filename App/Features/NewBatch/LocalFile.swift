import Foundation
import ProteinApplication
import SequenceIO

struct FASTAInspection: Sendable {
    let id = UUID()
    let filename: String
    let byteCount: Int
    let records: [ProteinImportRecord]

    static let extensions = ["fasta", "faa", "fa", "fas", "txt"]

    init(url: URL) throws {
        guard Self.extensions.contains(url.pathExtension.lowercased()) else {
            throw LocalFileError.unsupportedFASTAExtension
        }
        filename = url.lastPathComponent
        let data = try LocalFile.read(at: url, maximumBytes: FASTAReader.maximumFileBytes) { size in
            guard size <= FASTAReader.maximumFileBytes else {
                throw FASTAReadError.fileTooLarge(limit: FASTAReader.maximumFileBytes)
            }
        }
        byteCount = data.count
        records = try ProteinImport.read(fastaData: data)
    }
}

enum LocalFileError: Error {
    case unsupportedFASTAExtension
}

enum LocalFile {
    static func read(at url: URL, maximumBytes: Int, validateSize: (Int) throws -> Void) throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer { if hasScopedAccess { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        try validateSize(size)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let readLimit = maximumBytes + 1
        var data = Data()
        while data.count < readLimit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, readLimit - data.count)), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        try validateSize(data.count)
        return data
    }
}
