import Foundation

struct WorkbookDates {
    private enum Format {
        case date, time, dateTime
    }

    let uses1904Dates: Bool
    private var cellFormats: [Int] = []
    private var customDates: [Int: Format] = [:]

    init(uses1904Dates: Bool) {
        self.uses1904Dates = uses1904Dates
    }

    mutating func readStyles(_ data: Data) throws {
        var cellFormats: [Int] = []
        var customDates: [Int: Format] = [:]
        try WorkbookXML.read(data, root: "styleSheet", start: { path, attributes in
            guard let id = attributes["numFmtId"].flatMap(Int.init) else { return }
            switch path {
            case ["styleSheet", "numFmts", "numFmt"]:
                if let code = attributes["formatCode"], let format = Self.dateFormat(for: code) {
                    customDates[id] = format
                }
            case ["styleSheet", "cellXfs", "xf"]:
                cellFormats.append(id)
            default: break
            }
            guard cellFormats.count <= 65_536, customDates.count <= 65_536 else {
                throw SpreadsheetReadError.importLimitExceeded
            }
        })
        self.cellFormats = cellFormats
        self.customDates = customDates
    }

    func render(_ value: String, style: Int) -> String {
        guard cellFormats.indices.contains(style), let serial = Double(value), serial >= 0, serial < 2_958_466,
              let format = format(for: cellFormats[style]) else { return value }
        let day = Int(serial)
        let seconds = Int(((serial - Double(day)) * 86_400).rounded())
        let clockSeconds = seconds % 86_400
        let time = String(format: "%02d:%02d:%02d", clockSeconds / 3_600, clockSeconds / 60 % 60, clockSeconds % 60)
        if format == .time { return time }
        let displayDay = day + seconds / 86_400
        let date: String
        if !uses1904Dates && displayDay == 60 {
            date = "1900-02-29"
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let epoch = uses1904Dates ? Date(timeIntervalSince1970: -2_082_844_800) : Date(timeIntervalSince1970: -2_209_075_200)
            let adjusted = !uses1904Dates && displayDay >= 61 ? displayDay - 1 : displayDay
            let components = calendar.dateComponents([.year, .month, .day], from: epoch.addingTimeInterval(Double(adjusted) * 86_400))
            guard let year = components.year, year <= 9_999, let month = components.month, let day = components.day else {
                return value
            }
            date = String(format: "%04d-%02d-%02d", year, month, day)
        }
        return format == .date ? date : date + " " + time
    }

    private func format(for id: Int) -> Format? {
        if let custom = customDates[id] { return custom }
        switch id {
        case 14...17, 27...31, 34...36, 50...58: return .date
        case 18...21, 32...33, 45, 47: return .time
        case 22: return .dateTime
        default: return nil
        }
    }

    private static func dateFormat(for code: String) -> Format? {
        var iterator = code.lowercased().makeIterator()
        var quoted = false
        var tokens: Set<Character> = []
        while let character = iterator.next() {
            if character == "\"" { quoted.toggle(); continue }
            guard !quoted else { continue }
            switch character {
            case "\\", "_", "*": _ = iterator.next()
            case "[":
                var directive = ""
                while let next = iterator.next(), next != "]" { directive.append(next) }
                if ["h", "hh", "m", "mm", "s", "ss"].contains(directive) { return nil }
            case ";": return format(for: tokens)
            case "y", "d", "h", "s", "m": tokens.insert(character)
            default: break
            }
        }
        return format(for: tokens)
    }

    private static func format(for tokens: Set<Character>) -> Format? {
        let hasDate = tokens.contains("y") || tokens.contains("d")
        let hasTime = tokens.contains("h") || tokens.contains("s")
        if hasDate && hasTime { return .dateTime }
        if hasTime { return .time }
        return hasDate || tokens.contains("m") ? .date : nil
    }
}
