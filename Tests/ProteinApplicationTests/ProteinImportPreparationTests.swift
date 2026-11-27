import Foundation
import ProteinApplication
import ProteinDomain
import SequenceIO
import Testing

struct ProteinImportPreparationTests {
    @Test func sizeLimitIsInclusiveAndPreservesReaderErrors() throws {
        let limit = ProteinDomainLimits.maximumTextBytes
        let atLimit = "M" + String(repeating: " ", count: limit - 1)
        #expect(try ProteinImport.read(pastedText: atLimit).map(\.rawSequence) == ["M"])
        #expect(try ProteinImport.read(fastaData: Data(atLimit.utf8)).map(\.rawSequence) == ["M"])
        #expect(throws: FASTAReadError.fileTooLarge(limit: limit)) {
            try ProteinImport.read(pastedText: atLimit + " ")
        }
        let tooLarge = Data(repeating: 0, count: limit + 1)
        #expect(throws: FASTAReadError.fileTooLarge(limit: limit)) { try ProteinImport.read(fastaData: tooLarge) }
        #expect(throws: SpreadsheetInputError.fileTooLarge(limit: limit)) {
            try SpreadsheetReader.read(tooLarge, format: .csv)
        }
    }

    @Test func countLimitDoesNotSuppressDiscoverableRecordIssues() throws {
        let maximum = ProteinDomainLimits.maximumRecords
        let empty = try ProteinImport.validate([])
        #expect(empty.batchIssues == [.recordCount(limit: 1...maximum)])
        #expect(!empty.isValid)
        let full = String(repeating: ">repeat\nQ\n", count: maximum)
        let included = try ProteinImport.validate(ProteinImport.read(pastedText: full))
        let preview = try ProteinImport.prepare(name: "Full", validation: included)
        #expect(preview.recordCount == maximum)
        #expect(preview.records.last?.position == maximum)
        let exceeded = try ProteinImport.validate(ProteinImport.read(pastedText: full + ">last\n?\n"))
        #expect(exceeded.batchIssues == [.recordCount(limit: 1...maximum)])
        #expect(exceeded.records.count == maximum + 1)
        #expect(exceeded.records.last?.issues == [.input(.sequence(.invalidResidue(position: 1)))])
        #expect(!exceeded.isValid)
    }

    @Test func sequenceAndBatchLengthsFollowDomainIncludingTerminalStop() throws {
        let maximum = ProteinDomainLimits.maximumSequenceLength
        let totalLimit = ProteinDomainLimits.maximumBatchLength
        let longSequence = String(repeating: "W", count: maximum)
        let longInput = try ProteinImport.read(pastedText: longSequence)
        let preserved = try ProteinImport.validate(longInput)
        #expect(preserved.isValid)
        let preservePreview = try ProteinImport.prepare(name: "Limit", validation: preserved)
        #expect(preservePreview.submittedSequenceLength == maximum)
        let added = try ProteinImport.validate(longInput, parameters: .init(stopPolicy: .add))
        #expect(added.records.map(\.issues) == [[.input(.sequence(.stopAdditionExceedsLimit(limit: maximum)))]])
        #expect(added.records.first?.originalSequence?.value == longSequence)
        let tooLong = try ProteinImport.validate(ProteinImport.read(pastedText: longSequence + "*"))
        #expect(tooLong.records.map(\.issues) == [[.input(.sequence(.tooLong(limit: maximum)))]])

        let fullBatch = String(repeating: ">row\n\(longSequence)\n", count: totalLimit / maximum)
        let full = try ProteinImport.validate(ProteinImport.read(pastedText: fullBatch))
        #expect(full.isValid)
        #expect(try ProteinImport.prepare(name: "Total limit", validation: full).originalSequenceLength == totalLimit)
        let exceeded = try ProteinImport.validate(ProteinImport.read(pastedText: fullBatch + ">extra\nA\n"))
        #expect(exceeded.batchIssues == [.totalLengthExceedsLimit(limit: totalLimit)])
        #expect(exceeded.records.allSatisfy { $0.issues.isEmpty })
        #expect(!exceeded.isValid)
    }

    @Test func startCodonChangesNewFingerprintsButNotLegacyNone() throws {
        let input = BatchInput.records([.init(name: "A", sequence: "A")])
        let legacy = try BatchPreparation.prepare(name: "Policy", input: input, parameters: .init(stopPolicy: .add))
        let explicitNone = try BatchPreparation.prepare(name: "Policy", input: input,
                                                       parameters: .init(startPolicy: .none, stopPolicy: .add))
        let always = try BatchPreparation.prepare(name: "Policy", input: input,
                                                 parameters: .init(startPolicy: .always, stopPolicy: .add))
        let conditional = try BatchPreparation.prepare(name: "Policy", input: input,
                                                      parameters: .init(startPolicy: .ifNotMethionine, stopPolicy: .add))
        try PreviewIntegrity.verify(legacy)
        try PreviewIntegrity.verify(always)
        try PreviewIntegrity.verify(conditional)
        #expect(legacy.fingerprint == explicitNone.fingerprint)
        #expect(always.fingerprint != legacy.fingerprint)
        #expect(conditional.fingerprint != legacy.fingerprint)
        #expect(always.fingerprint != conditional.fingerprint)
        #expect(always.records[0].originalSequence.value == "A")
        #expect(always.records[0].sequence.value == "A*")
        #expect(conditional.records[0].sequence.value == "A*")
        #expect(legacy.records[0].sequence.value == "A*")
    }

    @Test func previewExposesFrozenLocalSummaryAndBatchErrors() throws {
        let source = ">first\n a Q\n>already\nW*\n"
        let records = try ProteinImport.read(pastedText: source)
        let parameters = try OptimizationParameters(
            species: .chineseHamsterOvary, stopPolicy: .add, avoid: AvoidMotifs(" a c g , ACG ")
        )
        let validation = try ProteinImport.validate(records, parameters: parameters)
        let now = Date(timeIntervalSince1970: 100)
        let preview = try ProteinImport.prepare(name: "Preview", validation: validation, requestID: "local", now: now)

        #expect(preview.recordCount == 2)
        #expect(preview.records.map(\.originalSequence.value) == ["AQ", "W*"])
        #expect(preview.records.map(\.submittedSequence.value) == ["AQ*", "W*"])
        #expect(preview.records.map(\.source) == [.paste(line: 1), .paste(line: 3)])
        #expect(preview.originalSequenceLength == 4)
        #expect(preview.submittedSequenceLength == 5)
        #expect(preview.parameters == parameters)
        #expect(preview.finalMotifs == ["ACG"])
        #expect(preview.endpoint == Batch.serviceEndpoint)
        #expect(preview.batch.status == .prepared)
        #expect(preview.batch.authorizedAt == nil)
        #expect(preview.batch.requestID == "local")
        #expect(preview.batch.createdAt == now)
        try PreviewIntegrity.verify(preview.batch)

        let same = try ProteinImport.prepare(name: "Preview", validation: validation, requestID: "other", now: now + 1)
        #expect(preview.fingerprint == same.fingerprint)
        let changed = try ProteinImport.prepare(name: "Renamed", validation: validation)
        #expect(preview.fingerprint != changed.fingerprint)
        #expect(throws: BatchInputError.invalidBatchName) { try ProteinImport.prepare(name: " ", validation: validation) }
        #expect(throws: BatchInputError.invalidRequestID) {
            try ProteinImport.prepare(name: "Preview", validation: validation, requestID: "\n")
        }
    }
}
