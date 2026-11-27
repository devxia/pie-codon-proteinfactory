import Foundation

private let spreadsheetNamespaces = [
    "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "http://purl.oclc.org/ooxml/spreadsheetml/main",
]

final class WorkbookXML: NSObject, XMLParserDelegate {
    typealias Start = ([String], [String: String]) throws -> Void
    typealias Text = ([String], String) throws -> Void
    typealias End = ([String]) throws -> Void

    private let root: String
    private let namespaces: [String]
    private let start: Start
    private let text: Text
    private let end: End
    private var path: [String] = []
    private var failure: (any Error)?

    static func read(
        _ data: Data, root: String, namespaces: [String] = spreadsheetNamespaces,
        start: @escaping Start = { _, _ in },
        text: @escaping Text = { _, _ in },
        end: @escaping End = { _ in }
    ) throws {
        let encoding: String.Encoding = if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            .utf16
        } else {
            .utf8
        }
        guard let content = String(data: data, encoding: encoding),
              !content.utf8.contains(0), !content.contains("<!DOCTYPE"), !content.contains("<!ENTITY") else {
            throw SpreadsheetReadError.invalidWorkbook
        }

        let delegate = WorkbookXML(root: root, namespaces: namespaces, start: start, text: text, end: end)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed else { throw SpreadsheetReadError.invalidWorkbook }
    }

    private init(root: String, namespaces: [String], start: @escaping Start, text: @escaping Text, end: @escaping End) {
        self.root = root
        self.namespaces = namespaces
        self.start = start
        self.text = text
        self.end = end
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        let name = namespaces.contains(namespaceURI ?? "") ? elementName : ""
        handle(parser) {
            if path.isEmpty && name != root { throw SpreadsheetReadError.invalidWorkbook }
            guard path.count < 64 else { throw SpreadsheetReadError.importLimitExceeded }
            path.append(name)
            try start(path, attributes)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        handle(parser) {
            try end(path)
            path.removeLast()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        handle(parser) { try text(path, string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        handle(parser) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else {
                throw SpreadsheetReadError.invalidWorkbook
            }
            try text(path, string)
        }
    }

    private func handle(_ parser: XMLParser, _ action: () throws -> Void) {
        guard failure == nil else { return }
        do { try action() } catch {
            failure = error
            parser.abortParsing()
        }
    }
}

struct WorkbookText {
    private(set) var value = ""
    private var byteCount = 0

    mutating func append(_ fragment: String) throws {
        byteCount += fragment.utf8.count
        // An OOXML escaped UTF-16 code unit occupies seven ASCII bytes.
        guard byteCount <= SpreadsheetBudget.maximumCellCharacters * 7 else {
            throw SpreadsheetReadError.importLimitExceeded
        }
        value += fragment
    }

    func decoded() throws -> String {
        let result = value.contains("_x") ? Self.decodeEscapes(value) : value
        try SpreadsheetBudget.validateText(result)
        return result
    }

    private static func decodeEscapes(_ string: String) -> String {
        let codeUnits = Array(string.utf16)
        var result: [UInt16] = []
        var index = 0
        while index < codeUnits.count {
            if index + 6 < codeUnits.count, codeUnits[index] == 95, codeUnits[index + 1] == 120,
               codeUnits[index + 6] == 95,
               let value = UInt16(String(decoding: codeUnits[(index + 2)..<(index + 6)], as: UTF16.self), radix: 16) {
                result.append(value)
                index += 7
            } else {
                result.append(codeUnits[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF16.self)
    }
}
