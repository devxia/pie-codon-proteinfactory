import Foundation
import SequenceIO
import Testing

struct FASTATests {
    @Test func locatedReaderPreservesHeaderAndSequenceStartLines() throws {
        let headed = "\u{FEFF}\r\n>first\r\nma\r\n\r\n>second\r\nQT"
        let located = try FASTAReader.readLocated(Data(headed.utf8))
        #expect(located.map(\.sourceLine) == [2, 5])
        #expect(located.map(\.record) == (try FASTAReader.read(headed)))
        let headerless = try FASTAReader.readLocated("\n \t\n a Q\nM", defaultName: "Custom")
        #expect(headerless.map(\.sourceLine) == [3])
        #expect(headerless.map(\.record) == [.init(name: "Custom", originalSequence: "aQM")])
    }
    @Test func readsSingleSequenceWithoutAHeader() throws {
        let text = "\u{FEFF}\r\n m k\u{00A0}q*\r\n"
        #expect(try FASTAReader.read(text) == [FASTARecord(name: "Protein 1", originalSequence: "mkq*")])
        #expect(try FASTAReader.read(text, defaultName: "\u{2003} \t") == [
            FASTARecord(name: "Protein 1", originalSequence: "mkq*"),
        ])
        #expect(try FASTAReader.read(text, defaultName: "\tMy\r\n> sample \u{007F}") == [
            FASTARecord(name: "My _ sample", originalSequence: "mkq*"),
        ])
    }

    @Test func readsFixtureInOrderWithLFAndCRLF() throws {
        let url = try #require(Bundle.module.url(forResource: "proteins", withExtension: "faa", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let expected = [
            FASTARecord(name: "重复 _标签", originalSequence: "maT*"),
            FASTARecord(name: "重复 _标签", originalSequence: "rx-"),
            FASTARecord(name: "Third", originalSequence: "K>q"),
        ]
        #expect(try FASTAReader.read(data, defaultName: "unused") == expected)

        let lf = try #require(String(data: data, encoding: .utf8))
        let crlf = "\u{FEFF}" + lf.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try FASTAReader.read(Data(crlf.utf8)) == expected)
    }

    @Test(arguments: ["", "\u{FEFF}", " \t\r\n\u{2003}"])
    func rejectsEmptyInput(_ text: String) {
        #expect(throws: FASTAReadError.emptyInput) { try FASTAReader.read(text) }
        #expect(throws: FASTAReadError.emptyInput) { try FASTAReader.read(Data(text.utf8)) }
    }

    @Test(arguments: [
        ("\n> \t\u{200B}\nM", FASTAReadError.missingName(record: 1, line: 2)),
        (">first\r\nM\r\n>\r\nK", .missingName(record: 2, line: 3)),
        (">first\n\n>second\nM", .emptySequence(record: 1, line: 1)),
        (">first\nM\n>second\n \t", .emptySequence(record: 2, line: 3)),
        ("\n \t>first\nM", .malformedHeader(record: 1, line: 2)),
        (">first\nM\n>second\nK\n \t>third\nM", .malformedHeader(record: 3, line: 5)),
        ("\u{FEFF}\r\nM\r\n\r\n>first\r\nK", .sequenceBeforeHeader(record: 1, line: 2)),
    ])
    func locatesRecordErrors(_ text: String, _ error: FASTAReadError) {
        #expect(throws: error) { try FASTAReader.read(Data(text.utf8)) }
    }

    @Test func rejectsInvalidUTF8AndNUL() {
        #expect(throws: FASTAReadError.invalidUTF8) { try FASTAReader.read(Data([0x4D, 0xC3, 0x28])) }
        #expect(throws: FASTAReadError.containsNUL) { try FASTAReader.read(Data(">name\nM\0K".utf8)) }
        #expect(throws: FASTAReadError.containsNUL) { try FASTAReader.read(">na\0me\nMK") }
    }

    @Test func enforcesFiveMiBInUTF8BytesIncludingBOM() throws {
        let limit = 5 * 1_024 * 1_024
        #expect(FASTAReader.maximumFileBytes == limit)
        let suffix = "\nM"
        let exact = "\u{FEFF}>重" + String(repeating: " ", count: limit - 9) + suffix
        #expect(exact.utf8.count == limit)
        let records = try FASTAReader.read(Data(exact.utf8))
        #expect(records == [FASTARecord(name: "重", originalSequence: "M")])
        let oversized = exact + " "
        #expect(oversized.utf8.count == limit + 1)
        #expect(throws: FASTAReadError.fileTooLarge(limit: limit)) { try FASTAReader.read(Data(oversized.utf8)) }
        #expect(throws: FASTAReadError.fileTooLarge(limit: limit)) { try FASTAReader.read(oversized) }
    }

    @Test func wrapsLikeReferenceAndFoldsHeaderControls() throws {
        let firstLine = String(repeating: "A", count: 80)
        let secondLine = "A" + String(repeating: "C", count: 79)
        let records = [
            FASTARecord(name: "name\n>injected", originalSequence: firstLine + "A \t" + String(repeating: "C", count: 80)),
            FASTARecord(name: " next \u{2003}\u{0001}> id ", originalSequence: firstLine),
        ]
        let encoded = try FASTAWriter.write(records)
        #expect(encoded == Data(">name _injected\n\(firstLine)\n\(secondLine)\nC\n>next _ id\n\(firstLine)\n".utf8))
    }

    @Test func serializedRecordsRoundTripInCanonicalForm() throws {
        let first = String(repeating: "A", count: 79) + "e\u{0301}"
        let records = [
            FASTARecord(name: "name\r\n>", originalSequence: first),
            FASTARecord(name: "name _", originalSequence: "  m k\u{00A0}* "),
        ]
        let content = try FASTAWriter.write(records)
        let expected = ">name _\n" + String(repeating: "A", count: 79) + "e\n\u{0301}\n>name _\nmk*\n"
        #expect(content == Data(expected.utf8))
        let parsed = try FASTAReader.read(content)
        #expect(parsed == [
            FASTARecord(name: "name _", originalSequence: first),
            FASTARecord(name: "name _", originalSequence: "mk*"),
        ])
        #expect(try FASTAWriter.write(parsed) == content)
    }

    @Test func writesZeroBytesForAnEmptyArchiveMember() throws {
        #expect(try FASTAWriter.write([]) == Data())
    }

    @Test(arguments: [
        (FASTARecord(name: " \t\u{200B}", originalSequence: "A"), FASTAWriteError.missingName(record: 2)),
        (FASTARecord(name: "name", originalSequence: " \n\t"), .emptySequence(record: 2)),
        (FASTARecord(name: "na\0me", originalSequence: "A"), .containsNUL(record: 2)),
        (FASTARecord(name: "name", originalSequence: "A\0"), .containsNUL(record: 2)),
        (FASTARecord(name: "name", originalSequence: String(repeating: "A", count: 80) + ">bad"), .sequenceContainsHeaderDelimiter(record: 2)),
    ])
    func refusesInvalidRecordsDuringSerialization(_ record: FASTARecord, _ error: FASTAWriteError) {
        let valid = FASTARecord(name: "valid", originalSequence: "A")
        #expect(throws: error) { try FASTAWriter.write([valid, record]) }
    }
}
