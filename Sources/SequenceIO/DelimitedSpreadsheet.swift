import CoreFoundation
import Foundation

struct DelimitedSpreadsheet {
    private static let comma: UInt8 = 44
    private static let semicolon: UInt8 = 59
    private static let tab: UInt8 = 9
    private static let quote: UInt8 = 34
    private static let cr: UInt8 = 13
    private static let lf: UInt8 = 10

    static func read(_ data: Data, format: SpreadsheetFormat) throws -> SpreadsheetSheet {
        let text = try decode(data)
        let bytes = Array(text.utf8)
        let delimiter = format == .tsv ? tab : detectDelimiter(in: text, bytes: bytes)
        var field: [UInt8] = []
        var row: [String] = []
        var rows: [[String]] = []
        var sourceRows: [Int] = []
        var columnCount = 0
        var hasData = false
        var budget = SpreadsheetBudget()
        try scan(bytes[...], delimiter: delimiter, complete: true) { event in
            switch event {
            case let .byte(byte):
                field.append(byte)
                guard field.count <= SpreadsheetBudget.maximumCellCharacters * 4 else {
                    throw SpreadsheetReadError.importLimitExceeded
                }
            case .fieldEnd:
                guard row.count < SpreadsheetBudget.maximumColumns else {
                    throw SpreadsheetReadError.importLimitExceeded
                }
                let value = String(decoding: field, as: UTF8.self)
                try SpreadsheetBudget.validateText(value)
                try budget.add(value)
                hasData = hasData || !value.isEmpty
                row.append(value)
                field.removeAll(keepingCapacity: true)
            case .rowEnd(let startingAt):
                guard rows.count < SpreadsheetBudget.maximumRows else {
                    throw SpreadsheetReadError.importLimitExceeded
                }
                columnCount = max(columnCount, row.count)
                rows.append(row)
                sourceRows.append(startingAt)
                row = []
            }
        }
        guard hasData else { throw SpreadsheetReadError.emptyData }
        return SpreadsheetSheet(
            name: nil, rows: rows, sourceRows: sourceRows, columnCount: columnCount, containsFormulas: false
        )
    }

    private static func decode(_ data: Data) throws -> String {
        guard !data.contains(0) else { throw SpreadsheetReadError.invalidEncoding }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else {
                throw SpreadsheetReadError.invalidEncoding
            }
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        guard let decoded = data.withUnsafeBytes({ rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            return CFStringCreateWithBytes(nil, bytes.baseAddress, bytes.count, gb18030, false)
        }) else {
            throw SpreadsheetReadError.invalidEncoding
        }
        return decoded as String
    }

    private static func detectDelimiter(in text: String, bytes: [UInt8]) -> UInt8 {
        let sampleCount = String(text.unicodeScalars.prefix(8_192)).utf8.count
        var best = comma
        var bestMatches = 0
        var bestMismatches = Int.max
        var bestWidth = 0
        for delimiter in [comma, semicolon, tab] {
            var frequencies: [Int: Int] = [:]
            var width = 0
            var hasContent = false
            var records = 0
            do {
                try scan(bytes.prefix(sampleCount), delimiter: delimiter, complete: sampleCount == bytes.count) { event in
                    switch event {
                    case .byte: hasContent = true
                    case .fieldEnd: width += 1
                    case .rowEnd:
                        if hasContent || width > 1 {
                            frequencies[width, default: 0] += 1
                            records += 1
                        }
                        width = 0
                        hasContent = false
                    }
                }
            } catch {
                // Completed records still provide delimiter evidence for malformed files.
            }
            for (width, matches) in frequencies where width > 1 {
                let mismatches = records - matches
                if matches > bestMatches
                    || (matches == bestMatches && mismatches < bestMismatches)
                    || (matches == bestMatches && mismatches == bestMismatches && width > bestWidth) {
                    best = delimiter
                    bestMatches = matches
                    bestMismatches = mismatches
                    bestWidth = width
                }
            }
        }
        return best
    }

    private enum Event {
        case byte(UInt8)
        case fieldEnd
        case rowEnd(startingAt: Int)
    }

    private enum FieldState {
        case start
        case unquoted
        case quoted
        case afterQuote
    }

    private static func scan(
        _ bytes: ArraySlice<UInt8>, delimiter: UInt8, complete: Bool,
        consume: (Event) throws -> Void
    ) throws {
        var state = FieldState.start
        var index = bytes.startIndex
        var line = 1
        var rowStartLine = 1
        var pendingRow = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if state == .quoted {
                if byte == quote {
                    state = .afterQuote
                } else {
                    try consume(.byte(byte))
                    if byte == cr {
                        line += 1
                        if index < bytes.endIndex, bytes[index] == lf {
                            try consume(.byte(lf))
                            index += 1
                        }
                    } else if byte == lf {
                        line += 1
                    }
                }
                continue
            }
            switch byte {
            case delimiter:
                try consume(.fieldEnd)
                state = .start
                pendingRow = true
            case cr, lf:
                if byte == cr, index < bytes.endIndex, bytes[index] == lf { index += 1 }
                try consume(.fieldEnd)
                try consume(.rowEnd(startingAt: rowStartLine))
                line += 1
                rowStartLine = line
                state = .start
                pendingRow = false
            case quote:
                switch state {
                case .start: state = .quoted
                case .afterQuote:
                    try consume(.byte(quote))
                    state = .quoted
                default: throw SpreadsheetReadError.malformedDelimitedText
                }
                pendingRow = true
            default:
                guard state != .afterQuote else { throw SpreadsheetReadError.malformedDelimitedText }
                try consume(.byte(byte))
                state = .unquoted
                pendingRow = true
            }
        }
        guard complete else { return }
        guard state != .quoted else { throw SpreadsheetReadError.malformedDelimitedText }
        if pendingRow {
            try consume(.fieldEnd)
            try consume(.rowEnd(startingAt: rowStartLine))
        }
    }
}
