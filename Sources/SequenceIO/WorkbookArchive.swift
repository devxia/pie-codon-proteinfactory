import Foundation
import ZIPFoundation

struct WorkbookArchive {
    private static let maximumMembers = 1_000
    private static let maximumExpandedBytes: UInt64 = 40 * 1_024 * 1_024

    private let archive: Archive
    private let entries: [String: Entry]

    init(_ data: Data) throws {
        // ZIPFoundation stops iterating at an unreadable entry. Compare against the central
        // directory's count so a partially readable archive is rejected as a whole.
        let count = try Self.memberCount(in: Array(data))
        archive = try Archive(data: data, accessMode: .read)
        var entries: [String: Entry] = [:]
        var remaining = Self.maximumExpandedBytes
        for entry in archive {
            guard entries.count < count, entry.type != .symlink, !entry.path.isEmpty,
                  entries[entry.path] == nil else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            guard entry.uncompressedSize <= remaining else {
                throw SpreadsheetReadError.importLimitExceeded
            }
            remaining -= entry.uncompressedSize
            entries[entry.path] = entry
        }
        guard entries.count == count else { throw SpreadsheetReadError.invalidWorkbook }
        self.entries = entries
    }

    func read(_ path: String) throws -> Data {
        guard let entry = entries[path], entry.type == .file else {
            throw SpreadsheetReadError.invalidWorkbook
        }
        var data = Data()
        let checksum = try archive.extract(entry) { chunk in
            guard UInt64(data.count + chunk.count) <= entry.uncompressedSize else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            data.append(chunk)
        }
        guard checksum == entry.checksum, UInt64(data.count) == entry.uncompressedSize else {
            throw SpreadsheetReadError.invalidWorkbook
        }
        return data
    }

    private static func memberCount(in bytes: [UInt8]) throws -> Int {
        func read16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func read32(_ offset: Int) -> Int {
            read16(offset) | read16(offset + 2) << 16
        }

        let recordLength = 22
        guard bytes.count >= recordLength else { throw SpreadsheetReadError.invalidWorkbook }
        let last = bytes.count - recordLength
        let first = max(0, last - 65_535)
        guard let end = (first...last).reversed().first(where: {
            read32($0) == 0x06054B50 && read16($0 + 20) == last - $0
        }) else { throw SpreadsheetReadError.invalidWorkbook }

        let count = read16(end + 10)
        let directorySize = read32(end + 12)
        let directoryStart = read32(end + 16)
        guard read16(end + 4) == 0, read16(end + 6) == 0, read16(end + 8) == count,
              count > 0, directoryStart + directorySize == end else {
            throw SpreadsheetReadError.invalidWorkbook
        }
        guard count <= maximumMembers else { throw SpreadsheetReadError.importLimitExceeded }

        var offset = directoryStart
        for _ in 0..<count {
            guard offset + 46 <= end, read32(offset) == 0x02014B50 else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            let flags = read16(offset + 8)
            let compressedSize = read32(offset + 20)
            let nameLength = read16(offset + 28)
            let local = read32(offset + 42)
            guard flags & 0x2041 == 0, read16(offset + 34) == 0, nameLength > 0,
                  local + 30 <= directoryStart, read32(local) == 0x04034B50,
                  read16(local + 6) == flags, read16(local + 8) == read16(offset + 10),
                  read16(local + 26) == nameLength else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            let dataStart = local + 30 + nameLength + read16(local + 28)
            guard dataStart + compressedSize <= directoryStart, offset + 46 + nameLength <= end,
                  bytes[(local + 30)..<(local + 30 + nameLength)].elementsEqual(
                    bytes[(offset + 46)..<(offset + 46 + nameLength)]
                  ) else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            offset += 46 + nameLength + read16(offset + 30) + read16(offset + 32)
        }
        guard offset == end else { throw SpreadsheetReadError.invalidWorkbook }
        return count
    }
}
