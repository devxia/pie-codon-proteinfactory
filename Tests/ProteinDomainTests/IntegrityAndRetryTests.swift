import Foundation
import ProteinDomain
import Testing

struct IntegrityAndRetryTests {
    @Test func sha256UsesCanonicalLowercaseHexAndExactBytes() {
        let digest = SHA256Digest.hash("abc")
        #expect(digest.rawValue == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest(rawValue: digest.rawValue) == digest)
        #expect(SHA256Digest(rawValue: digest.rawValue.uppercased()) == nil)
        #expect(SHA256Digest.hash(Data([97, 98, 99])) == digest)
        #expect(SHA256Digest.hash("ABC") != digest)
    }

    @Test func previewFingerprintFreezesNamesOrderSequencesAndEachParameter() throws {
        let draft = [SequenceRecordInput(name: "first", sequence: " a c "), .init(name: "second", sequence: "m*")]
        let batch = try BatchPreparation.prepare(name: "Local", input: .records(draft), requestID: "one")
        let equivalent = try BatchPreparation.prepare(name: "Local", input: .text(">first\nAC\n>second\nM*"), requestID: "two")
        #expect(batch.id != equivalent.id)
        #expect(batch.fingerprint == equivalent.fingerprint)
        #expect(batch.records.map(\.inputSHA256) == [.hash("AC"), .hash("M*")])
        try PreviewIntegrity.verify(batch)

        for altered in [
            try BatchPreparation.prepare(name: "Session", input: .records(draft)),
            try BatchPreparation.prepare(name: "Local", input: .records(draft.reversed())),
            try BatchPreparation.prepare(name: "Local", input: .records([.init(name: "renamed", sequence: "AC"), draft[1]])),
            try BatchPreparation.prepare(name: "Local", input: .records([.init(name: "first", sequence: "AD"), draft[1]])),
            try BatchPreparation.prepare(name: "Local", input: .records(draft), parameters: .init(species: .escherichiaColi)),
            try BatchPreparation.prepare(name: "Local", input: .records(draft), parameters: .init(stopPolicy: .add)),
            try BatchPreparation.prepare(name: "Local", input: .records(draft), parameters: .init(avoid: try AvoidMotifs("CCC"))),
        ] {
            #expect(altered.fingerprint != batch.fingerprint)
        }
        let stopAdded = try BatchPreparation.prepare(name: "Local", input: .text("A"), parameters: .init(stopPolicy: .add))
        let stopPresent = try BatchPreparation.prepare(name: "Local", input: .text("A*"), parameters: .init(stopPolicy: .add))
        #expect(stopAdded.records.map(\.inputSHA256) == stopPresent.records.map(\.inputSHA256))
        #expect(stopAdded.fingerprint != stopPresent.fingerprint)
        let preserveStop = try BatchPreparation.prepare(name: "Local", input: .text("A*"))
        #expect(preserveStop.records.map(\.inputSHA256) == stopPresent.records.map(\.inputSHA256))
        #expect(preserveStop.fingerprint != stopPresent.fingerprint)
    }

    @Test func staleFingerprintEndpointAndInputDigestAreRejected() throws {
        var batch = try BatchPreparation.prepare(name: "Batch", input: .text(">one\nA\n>two\nM"))
        let otherEndpoint = try #require(URL(string: "https://example.invalid/local-test"))
        #expect(throws: PreviewIntegrityError.endpointMismatch) {
            try PreviewIntegrity.verify(Batch(
                id: batch.id, requestID: batch.requestID, name: batch.name, parameters: batch.parameters,
                endpoint: otherEndpoint, fingerprint: batch.fingerprint, records: batch.records,
                createdAt: batch.createdAt, updatedAt: batch.updatedAt
            ))
        }
        #expect(throws: PreviewIntegrityError.fingerprintMismatch) {
            try PreviewIntegrity.verify(Batch(
                id: batch.id, requestID: batch.requestID, name: "Renamed", parameters: batch.parameters,
                endpoint: batch.endpoint, fingerprint: batch.fingerprint, records: batch.records,
                createdAt: batch.createdAt, updatedAt: batch.updatedAt
            ))
        }
        batch.records.swapAt(0, 1)
        #expect(throws: PreviewIntegrityError.recordLayoutMismatch(position: 1)) { try PreviewIntegrity.verify(batch) }
        batch.records.swapAt(0, 1)
        let record = batch.records[1]
        batch.records[1] = SequenceRecord(
            id: record.id, batchID: record.batchID, position: record.position, name: record.name,
            originalSequence: record.originalSequence, sequence: record.sequence, inputSHA256: .hash("tampered")
        )
        #expect(throws: PreviewIntegrityError.inputHashMismatch(position: 2)) { try PreviewIntegrity.verify(batch) }
    }

    @Test func finalBatchStatusUsesRequiredPriority() {
        #expect(BatchSummary(statuses: [.completed, .failed, .pending, .unknown]).statusAfterExecution == .unknown)
        #expect(BatchSummary(statuses: [.completed, .completed]).statusAfterExecution == .completed)
        #expect(BatchSummary(statuses: [.completed, .failed, .pending]).statusAfterExecution == .stopped)
        #expect(BatchSummary(statuses: [.completed, .failed]).statusAfterExecution == .partial)
        #expect(BatchSummary(statuses: [.failed, .failed]).statusAfterExecution == .failed)
        #expect(BatchSummary(statuses: [.running, .pending]).statusAfterExecution == nil)
        let summary = BatchSummary(statuses: [.completed, .failed, .unknown, .pending, .running])
        #expect(summary.total == 5)
        #expect(summary.done == 3)
        #expect(summary.pending == 1 && summary.running == 1 && summary.completed == 1 && summary.failed == 1 && summary.unknown == 1)
    }

    @Test func retryRequiresUnknownConfirmationAndOnlySkipsReverifiedCompletedRecords() throws {
        var batch = try BatchPreparation.prepare(name: "Retry", input: .text(">complete\nA\n>failed\nA\n>unknown\nA"))
        batch.status = .unknown
        batch.records[0].status = .completed
        batch.records[0].dna = "GCT"
        batch.records[0].dnaSHA256 = .hash("GCT")
        batch.records[1].status = .failed
        batch.records[2].status = .unknown
        #expect(throws: RetryError.unknownEffectRequiresConfirmation) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        let plan = try RetryPolicy.plan(for: batch, intent: .confirmedUnknownEffect)
        #expect(plan.recordIDsToRetry == [batch.records[1].id, batch.records[2].id])
        #expect(plan.completedRecordIDsToSkip == [batch.records[0].id])
        #expect(batch.records.map(\.status) == [.completed, .failed, .unknown])

        batch.records[0].dna = "GCC"
        #expect(throws: SavedDNAError.hashMismatch) { try DNAValidation.reverifyCompleted(batch.records[0], avoiding: batch.parameters.avoid) }
        #expect(throws: RetryError.invalidCompletedRecord(position: 1, reason: .hashMismatch)) {
            try RetryPolicy.plan(for: batch, intent: .confirmedUnknownEffect)
        }
        batch.records[0].dna = "AAA"
        batch.records[0].dnaSHA256 = .hash("AAA")
        #expect(throws: RetryError.failedCompletedRecordVerification(position: 1, reason: .translationMismatch(position: 1, expected: "A", actual: "K"))) {
            try RetryPolicy.plan(for: batch, intent: .confirmedUnknownEffect)
        }
        batch.records[0].dna = nil
        #expect(throws: RetryError.invalidCompletedRecord(position: 1, reason: .missingDNAOrHash)) {
            try RetryPolicy.plan(for: batch, intent: .confirmedUnknownEffect)
        }
    }

    @Test func retryHonorsAttemptLimitPerRecordAndRejectsActiveStates() throws {
        var batch = try BatchPreparation.prepare(name: "Retry", input: .text(">complete\nA\n>failed\nM"))
        #expect(throws: RetryError.invalidBatchState(.prepared)) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        batch.status = .queued
        #expect(throws: RetryError.invalidBatchState(.queued)) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        batch.status = .running
        #expect(throws: RetryError.invalidBatchState(.running)) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        batch.status = .partial
        batch.records[0].status = .completed
        batch.records[0].dna = "GCT"
        batch.records[0].dnaSHA256 = .hash("GCT")
        batch.records[1].status = .failed
        let attempts = (1...10).map { RequestAttempt(number: $0, startedAt: batch.createdAt, payloadSHA256: .hash("payload")) }
        batch.records[0].attempts = attempts
        batch.records[1].attempts = Array(attempts.dropLast())
        #expect(try RetryPolicy.plan(for: batch, intent: .ordinary).recordIDsToRetry == [batch.records[1].id])
        batch.records[1].attempts = attempts
        #expect(throws: RetryError.attemptLimit(position: 2, limit: 10)) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        batch.records[1].status = .running
        #expect(throws: RetryError.recordStillRunning(position: 2)) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
        batch.records[1].status = .completed
        #expect(throws: RetryError.noPendingRecords) { try RetryPolicy.plan(for: batch, intent: .ordinary) }
    }
}
