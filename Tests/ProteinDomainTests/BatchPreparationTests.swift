import ProteinDomain
import Testing

struct BatchPreparationTests {
    @Test func recordNameValidationIsSharedWithPreparation() throws {
        let maximum = String(repeating: "😀", count: 150)
        #expect(BatchPreparation.validatedRecordName(maximum) == maximum)
        #expect(BatchPreparation.validatedRecordName("  sample  ") == "sample")
        let accepted = try BatchPreparation.prepare(name: "Batch", input: .records([.init(name: maximum, sequence: "Q")]))
        #expect(accepted.records.map(\.name) == [maximum])
        for invalid in [maximum + " ", "x\ty", "x\u{007F}y", "   "] {
            #expect(BatchPreparation.validatedRecordName(invalid) == nil)
            #expect(throws: BatchInputError.record(location: .init(position: 1, sourceRow: 7), reason: .invalidName)) {
                try BatchPreparation.prepare(name: "Batch", input: .records([.init(name: invalid, sequence: "Q", sourceRow: 7)]))
            }
        }
    }
    @Test func standardResiduesAreNormalizedWithoutAddingMethionine() throws {
        let input = "\u{FEFF}acdefg\t hiklmn \u{00A0}pqr\u{FEFF}stvwy\r\n*"
        let sequence = try ProteinSequence(input)
        #expect(sequence.value == "ACDEFGHIKLMNPQRSTVWY*")
        #expect(sequence.residueCount == 20)
        #expect(sequence.hasTerminalStop)
        #expect(try sequence.applying(.add) == sequence)
        #expect(try sequence.applying(.preserve) == sequence)

        let batch = try BatchPreparation.prepare(name: "Local", input: .text(" a \t c ", singleRecordName: " input "))
        #expect(batch.status == .prepared)
        #expect(batch.authorizedAt == nil)
        #expect(batch.records.map(\.name) == ["input"])
        #expect(batch.records.map(\.sequence.value) == ["AC"])
        #expect(batch.records.allSatisfy { $0.status == .pending && $0.attempts.isEmpty })
    }

    @Test(arguments: ["B", "J", "O", "U", "X", "Z", "1", "-", "ß", "ſ", "K", "\u{0000}"])
    func invalidResiduesAreNotTransformedIntoValidLetters(_ invalid: String) {
        #expect(throws: ProteinSequenceError.invalidResidue(position: 2)) { try ProteinSequence("A \(invalid)") }
    }

    @Test func invalidAsteriskPlacementsAreRejected() {
        #expect(throws: ProteinSequenceError.empty) { try ProteinSequence("\u{FEFF} \r\n") }
        #expect(throws: ProteinSequenceError.misplacedStop(position: 1)) { try ProteinSequence("*") }
        #expect(throws: ProteinSequenceError.misplacedStop(position: 1)) { try ProteinSequence("*A") }
        #expect(throws: ProteinSequenceError.misplacedStop(position: 2)) { try ProteinSequence("A*\tC") }
        #expect(throws: ProteinSequenceError.misplacedStop(position: 2)) { try ProteinSequence("A* *") }
    }

    @Test func fastaAndMappedRowsIdentifyInvalidRecords() throws {
        let batch = try BatchPreparation.prepare(
            name: "Synthetic FASTA", input: .text("\u{FEFF}\r\n  >first\r\n aC\r\n d e\r\n\r\n>second\nM*\n"),
            parameters: .init(stopPolicy: .add)
        )
        #expect(batch.records.map(\.name) == ["first", "second"])
        #expect(batch.records.map(\.position) == [1, 2])
        #expect(batch.records.map(\.originalSequence.value) == ["ACDE", "M*"])
        #expect(batch.records.map(\.sequence.value) == ["ACDE*", "M*"])
        #expect(batch.originalSequenceLength == 6)
        #expect(batch.submittedSequenceLength == 7)

        #expect(throws: BatchInputError.record(location: .init(position: 2, sourceRow: 5), reason: .sequence(.invalidResidue(position: 2)))) {
            try BatchPreparation.prepare(name: "FASTA", input: .text("\u{FEFF}\n>first\nA\n\n>second\nA?"))
        }
        #expect(throws: BatchInputError.record(location: .init(position: 2, sourceRow: 3), reason: .invalidName)) {
            try BatchPreparation.prepare(name: "FASTA", input: .text(">first\nA\n> \nA"))
        }
        #expect(throws: BatchInputError.record(location: .init(position: 2, sourceRow: 19), reason: .sequence(.empty))) {
            try BatchPreparation.prepare(name: "Mapped", input: .records([
                .init(name: "good", sequence: "A", sourceRow: 7),
                .init(name: "bad", sequence: " ", sourceRow: 19),
            ]))
        }
    }

    @Test func blankFASTALinesDoNotChangeTheLocatedHeader() {
        let filler = String(repeating: "\r\n", count: 100_000)
        #expect(throws: BatchInputError.record(location: .init(position: 2, sourceRow: 100_003), reason: .sequence(.empty))) {
            try BatchPreparation.prepare(name: "FASTA", input: .text(">first\nA\n" + filler + ">second\n"))
        }
    }

    @Test func batchRecordCountBoundaries() throws {
        let record = SequenceRecordInput(name: "Synthetic", sequence: "A")
        for count in [1, 200] {
            let batch = try BatchPreparation.prepare(name: "Count", input: .records(Array(repeating: record, count: count)))
            #expect(batch.records.count == count)
        }
        for count in [0, 201] {
            #expect(throws: BatchInputError.recordCount(limit: 1...200)) {
                try BatchPreparation.prepare(name: "Count", input: .records(Array(repeating: record, count: count)))
            }
        }
        let tooManyFASTA = String(repeating: ">synthetic\nA\n", count: 201)
        #expect(throws: BatchInputError.recordCount(limit: 1...200)) {
            try BatchPreparation.prepare(name: "FASTA", input: .text(tooManyFASTA))
        }
    }

    @Test func perSequenceLimitsApplyBeforeAndAfterAddingAStop() throws {
        let full = String(repeating: "A", count: 10_000)
        let sequence = try ProteinSequence(full)
        #expect(sequence.residueCount == 10_000)
        #expect(throws: ProteinSequenceError.tooLong(limit: 10_000)) { try ProteinSequence(full + "A") }
        #expect(throws: BatchInputError.record(location: .init(position: 1), reason: .sequence(.stopAdditionExceedsLimit(limit: 10_000)))) {
            try BatchPreparation.prepare(name: "Long", input: .text(full), parameters: .init(stopPolicy: .add))
        }
        let shorter = try ProteinSequence(String(full.dropLast()))
        let withStop = try shorter.applying(.add)
        #expect(withStop.value.utf8.count == 10_000)
        #expect(try withStop.applying(.add) == withStop)
        #expect(try ProteinSequence(withStop.value) == withStop)
    }

    @Test func batchTotalUsesNormalizedOriginalCharactersIncludingOriginalStops() throws {
        let sequence = String(repeating: "A", count: 1_000)
        let records = Array(repeating: SequenceRecordInput(name: "Synthetic", sequence: sequence + " \t"), count: 200)
        let batch = try BatchPreparation.prepare(name: "Total", input: .records(records), parameters: .init(stopPolicy: .add))
        #expect(batch.originalSequenceLength == 200_000)
        #expect(batch.submittedSequenceLength == 200_200)
        #expect(throws: BatchInputError.totalLengthExceedsLimit(limit: 200_000)) {
            let above = Array(records.dropLast()) + [.init(name: "Synthetic", sequence: sequence + "*")]
            return try BatchPreparation.prepare(name: "Total", input: .records(above))
        }
    }

    @Test func textSizeUsesUTF8BytesBeforeNormalization() throws {
        let limit = 5 * 1_024 * 1_024
        let prefix = "a" + String(repeating: " ", count: limit - 2)
        let batch = try BatchPreparation.prepare(name: "At byte limit", input: .text(prefix + " "))
        #expect(batch.records.first?.sequence.value == "A")
        #expect(throws: BatchInputError.textTooLarge(limit: limit)) {
            try BatchPreparation.prepare(name: "Above byte limit", input: .text(prefix + "\u{00A0}"))
        }
    }
}
