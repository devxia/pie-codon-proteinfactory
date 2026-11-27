import Foundation

public struct FASTARecord: Equatable, Sendable {
    public let name: String
    public let originalSequence: String

    public init(name: String, originalSequence: String) {
        self.name = name
        self.originalSequence = originalSequence
    }
}

public struct LocatedFASTARecord: Equatable, Sendable {
    public let record: FASTARecord
    /// One-based line of the header, or first sequence content when there is no header.
    public let sourceLine: Int
}

/// Record positions and source line numbers are one-based.
public enum FASTAReadError: Error, Equatable, Sendable {
    case fileTooLarge(limit: Int)
    case invalidUTF8
    case containsNUL
    case emptyInput
    case sequenceBeforeHeader(record: Int, line: Int)
    case malformedHeader(record: Int, line: Int)
    case missingName(record: Int, line: Int)
    case emptySequence(record: Int, line: Int)
}

public enum FASTAReader {
    public static let maximumFileBytes = 5 * 1_024 * 1_024

    public static func read(_ data: Data, defaultName: String? = nil) throws -> [FASTARecord] {
        try readLocated(data, defaultName: defaultName).map(\.record)
    }

    public static func read(_ text: String, defaultName: String? = nil) throws -> [FASTARecord] {
        try readLocated(text, defaultName: defaultName).map(\.record)
    }

    public static func readLocated(_ data: Data, defaultName: String? = nil) throws -> [LocatedFASTARecord] {
        try validateSize(data.count)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FASTAReadError.invalidUTF8
        }
        return try parse(text, defaultName: defaultName)
    }

    public static func readLocated(_ text: String, defaultName: String? = nil) throws -> [LocatedFASTARecord] {
        try validateSize(text.utf8.count)
        return try parse(text, defaultName: defaultName)
    }

    private static func validateSize(_ size: Int) throws {
        guard size <= maximumFileBytes else {
            throw FASTAReadError.fileTooLarge(limit: maximumFileBytes)
        }
    }

    private static func parse(_ text: String, defaultName: String?) throws -> [LocatedFASTARecord] {
        let input = text.unicodeScalars
        guard !input.contains("\0") else { throw FASTAReadError.containsNUL }

        var lineStart = input.first == "\u{FEFF}" ? input.index(after: input.startIndex) : input.startIndex
        var lineNumber = 0
        var firstSequenceLine: Int?
        var header: (name: String, line: Int)?
        var sequence = ""
        var records: [LocatedFASTARecord] = []

        func appendRecord(name: String, line: Int) throws {
            guard !sequence.isEmpty else {
                throw FASTAReadError.emptySequence(record: records.count + 1, line: line)
            }
            records.append(.init(record: .init(name: name, originalSequence: sequence), sourceLine: line))
            sequence = ""
        }

        while lineStart != input.endIndex {
            let lineEnd = input[lineStart...].firstIndex(of: "\n") ?? input.endIndex
            let line = input[lineStart..<lineEnd]
            lineStart = lineEnd == input.endIndex ? lineEnd : input.index(after: lineEnd)
            lineNumber += 1
            guard let contentStart = line.firstIndex(where: { !$0.properties.isWhitespace }) else { continue }

            if line[contentStart] == ">" {
                guard contentStart == line.startIndex else {
                    let nextRecord = records.count + (header == nil ? 1 : 2)
                    throw FASTAReadError.malformedHeader(record: nextRecord, line: lineNumber)
                }
                if let header {
                    try appendRecord(name: header.name, line: header.line)
                } else if let firstSequenceLine {
                    throw FASTAReadError.sequenceBeforeHeader(record: 1, line: firstSequenceLine)
                }
                let name = FASTAHeader.fold(line.dropFirst())
                guard !name.isEmpty else {
                    throw FASTAReadError.missingName(record: records.count + 1, line: lineNumber)
                }
                header = (name, lineNumber)
            } else {
                if firstSequenceLine == nil { firstSequenceLine = lineNumber }
                for scalar in line[contentStart...] where !scalar.properties.isWhitespace {
                    sequence.unicodeScalars.append(scalar)
                }
            }
        }

        if let header {
            try appendRecord(name: header.name, line: header.line)
        } else {
            guard let firstSequenceLine else { throw FASTAReadError.emptyInput }
            let suppliedName = defaultName ?? ""
            guard !suppliedName.unicodeScalars.contains("\0") else { throw FASTAReadError.containsNUL }
            let name = FASTAHeader.fold(suppliedName.unicodeScalars)
            try appendRecord(name: name.isEmpty ? "Protein 1" : name, line: firstSequenceLine)
        }
        return records
    }
}

/// Record positions are one-based.
public enum FASTAWriteError: Error, Equatable, Sendable {
    case missingName(record: Int)
    case emptySequence(record: Int)
    case containsNUL(record: Int)
    case sequenceContainsHeaderDelimiter(record: Int)
}

public enum FASTAWriter {
    /// Writes caller-selected records as UTF-8 with LF endings. An empty list yields zero bytes.
    public static func write(_ records: [FASTARecord]) throws -> Data {
        var output = ""
        for (offset, record) in records.enumerated() {
            let position = offset + 1
            guard !record.name.unicodeScalars.contains("\0") else {
                throw FASTAWriteError.containsNUL(record: position)
            }
            let name = FASTAHeader.fold(record.name.unicodeScalars)
            guard !name.isEmpty else { throw FASTAWriteError.missingName(record: position) }
            output += ">\(name)\n"

            var column = 0
            for scalar in record.originalSequence.unicodeScalars where !scalar.properties.isWhitespace {
                guard scalar != "\0" else { throw FASTAWriteError.containsNUL(record: position) }
                guard scalar != ">" else { throw FASTAWriteError.sequenceContainsHeaderDelimiter(record: position) }
                if column == 80 {
                    output += "\n"
                    column = 0
                }
                output.unicodeScalars.append(scalar)
                column += 1
            }
            guard column > 0 else { throw FASTAWriteError.emptySequence(record: position) }
            output += "\n"
        }
        return Data(output.utf8)
    }
}

private enum FASTAHeader {
    static func fold(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var name = ""
        var needsSpace = false
        for scalar in scalars {
            let category = scalar.properties.generalCategory
            if scalar.properties.isWhitespace || category == .control || category == .format {
                needsSpace = !name.isEmpty
            } else {
                if needsSpace { name += " " }
                name.unicodeScalars.append(scalar == ">" ? "_" : scalar)
                needsSpace = false
            }
        }
        return name
    }
}
