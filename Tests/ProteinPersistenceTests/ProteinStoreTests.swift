import Foundation
import GRDB
import ProteinDomain
import ProteinPersistence
import Testing

struct ProteinStoreTests {
    @Test func reopensCompleteSnapshotsWithStableOrderAndNoRecalculation() throws {
        try withTemporaryDatabase { url in
            let special = ",GGT(A/T)ACC"
            let custom = String(repeating: "A", count: AvoidMotifs.maximumCustomLength - special.utf16.count) + special
            let avoid = try AvoidMotifs(custom, enzymes: RestrictionEnzyme.allCases)
            let parameters = OptimizationParameters(species: .chineseHamsterOvary, startPolicy: .always,
                                                    stopPolicy: .add, avoid: avoid)
            var batch = try sampleBatch(parameters: parameters)
            batch.authorizedAt = fixtureDate + 1.234567
            batch.updatedAt = fixtureDate + 2.345678
            batch.status = .partial
            batch.stopRequested = true
            batch.message = "Local result only"
            batch.records[0].status = .completed
            batch.records[0].dna = "GCTGCTTAA"
            batch.records[0].dnaSHA256 = .hash("GCTGCTTAA")
            batch.records[0].checks = DNAChecks(basePairCount: 9, aminoAcidCount: 2, gcPercent: 44.444444,
                                                hasTerminalStop: true, checkedMotifCount: 17)
            batch.records[0].attempts = [
                RequestAttempt(number: 1, startedAt: fixtureDate, payloadSHA256: .hash("payload-1"),
                               finishedAt: fixtureDate + 0.456789, status: .failed, effect: .rejected,
                               httpStatus: 400, elapsedMilliseconds: 457, response: Data(), error: "Rejected"),
                RequestAttempt(number: 2, startedAt: fixtureDate + 1, payloadSHA256: .hash("payload-2"),
                               finishedAt: fixtureDate + 1.987654, status: .completed, effect: .completed,
                               httpStatus: 200, elapsedMilliseconds: 988, response: Data([0, 1, 255])),
            ]
            batch.records[1].status = .failed
            batch.records[1].checks = batch.records[0].checks
            batch.records[1].error = "A retained check snapshot with no DNA"
            var shuffled = batch
            shuffled.records[0].attempts.reverse()
            shuffled.records.reverse()
            try ProteinStore(url: url).saveBatch(shuffled)

            let store = try ProteinStore(url: url)
            #expect(try store.batch(id: batch.id) == batch)
            #expect(try store.record(id: batch.records[1].id) == batch.records[1])
            #expect(try store.attempts(recordID: batch.records[0].id) == batch.records[0].attempts)
            #expect(try store.batch(id: UUID()) == nil)
            #expect(try store.record(id: UUID()) == nil)
        }
    }

    @Test func historyFiltersAndPagesWithoutWildcardExpansion() throws {
        try withTemporaryDatabase { url in
            let store = try ProteinStore(url: url)
            var first = try sampleBatch(name: "Alpha_50%\\样本")
            first.records[0].status = .completed
            first.records[1].status = .failed
            first.status = .partial
            var second = try sampleBatch(name: "ALPHAX50x样本")
            second.updatedAt += 1
            var third = try sampleBatch(name: "Other")
            third.updatedAt = second.updatedAt
            third.status = .unknown
            third.records[0].status = .unknown
            for batch in [first, second, third] { try store.saveBatch(batch) }

            let ordered = [second.id, third.id].sorted { $0.uuidString < $1.uuidString } + [first.id]
            #expect(try store.batchHistory().map(\.id) == ordered)
            #expect(try store.batchHistory(limit: 1, offset: 1).map(\.id) == [ordered[1]])
            #expect(try store.batchHistory(nameContaining: "  alpha ").count == 2)
            #expect(try store.batchHistory(nameContaining: "_50%\\").map(\.id) == [first.id])
            #expect(try store.batchHistory(nameContaining: "样本", status: .prepared).map(\.id) == [second.id])
            #expect(try store.batchHistory(nameContaining: "alpha", status: .unknown).isEmpty)
            let summary = try #require(try store.batchHistory(status: .partial).first)
            #expect(summary.recordCount == 2)
            #expect(summary.completedCount == 1)
            #expect(summary.failedCount == 1)
            #expect(summary.unknownCount == 0)
            #expect(try store.records(batchID: first.id, status: .failed) == [first.records[1]])
            #expect(throws: PersistenceError.invalidHistoryPage) { try store.batchHistory(limit: 201) }
        }
    }

    @Test func uniquenessRollsBackParentsAndCascadeRemovesDescendants() throws {
        try withTemporaryDatabase { url in
            let store = try ProteinStore(url: url)
            var batch = try sampleBatch()
            let attempts = [sampleAttempt(1), sampleAttempt(1)]
            batch.records[0].attempts = attempts
            #expect(throws: DatabaseError.self) { try store.saveBatch(batch) }
            #expect(try store.batch(id: batch.id) == nil)
            #expect(try store.record(id: batch.records[0].id) == nil)
            #expect(try store.attempts(recordID: batch.records[0].id).isEmpty)

            batch.records[0].attempts = [attempts[0]]
            batch.records[1].attempts = [attempts[1]]
            try store.saveBatch(batch)
            var wrongParent = batch.records[1]
            wrongParent.attempts = [attempts[0]]
            #expect(throws: PersistenceError.invalidAttemptIdentity) { try store.saveRecord(wrongParent) }
            #expect(try store.batch(id: batch.id) == batch)
            #expect(try store.deleteBatch(id: batch.id))
            #expect(try !store.deleteBatch(id: batch.id))
            let db = try DatabaseQueue(path: url.path)
            let counts = try db.read { db in
                try ["batches", "records", "attempts"].map { try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") }
            }
            #expect(counts == [0, 0, 0])
        }
    }

    @Test func responseBoundIsEnforcedWithoutLosingExistingAudit() throws {
        try withTemporaryDatabase { url in
            let store = try ProteinStore(url: url)
            var batch = try sampleBatch()
            let limit = ProteinStore.maximumResponseBytes
            var attempt = sampleAttempt(1)
            attempt.response = Data(repeating: 0xFF, count: limit)
            batch.records[0].attempts = [attempt]
            try store.saveBatch(batch)

            batch.records[0].attempts[0].response?.append(0)
            #expect(throws: PersistenceError.responseTooLarge(limit: limit)) { try store.saveRecord(batch.records[0]) }
            #expect(try store.attempts(recordID: batch.records[0].id) == [attempt])
        }
    }

    @Test func historyLoadsResponseOnDemandAndGuardsDeletion() throws {
        try withTemporaryDatabase { url in
            let store = try ProteinStore(url: url)
            var batch = try sampleBatch()
            batch.status = .queued
            var attempt = sampleAttempt(1)
            attempt.response = Data([0, 1, 255])
            let empty = RequestAttempt(number: 2, startedAt: fixtureDate, payloadSHA256: .hash("empty"),
                                       status: .failed, effect: .rejected, response: Data())
            let missing = sampleAttempt(3)
            batch.records[0].attempts = [attempt, empty, missing]
            try store.saveBatch(batch)

            let detail = try #require(try store.batch(id: batch.id, includingResponses: false))
            #expect(detail.records[0].attempts.map(\.id) == [attempt.id, empty.id, missing.id])
            #expect(detail.records[0].attempts.allSatisfy { $0.response == nil })
            #expect(try store.attemptResponse(id: attempt.id, recordID: batch.records[0].id) == attempt.response)
            #expect(try store.attemptResponse(id: empty.id, recordID: batch.records[0].id) == Data())
            #expect(try store.attemptResponse(id: missing.id, recordID: batch.records[0].id) == nil)
            #expect(try store.attemptResponse(id: attempt.id, recordID: batch.records[1].id) == nil)
            #expect(try !store.deleteInactiveBatch(id: batch.id))
            batch.status = .running
            try store.saveBatch(batch)
            #expect(try !store.deleteInactiveBatch(id: batch.id))
            batch.status = .stopped
            try store.saveBatch(batch)
            #expect(try store.deleteInactiveBatch(id: batch.id))
            #expect(try store.attemptResponse(id: attempt.id, recordID: batch.records[0].id) == nil)
        }
    }

    @Test func presetsUseLocalOrderedCRUD() throws {
        try withTemporaryDatabase { url in
            let store = try ProteinStore(url: url)
            let first = try store.createPreset(name: "  中文预设  ", parameters: .init(), createdAt: fixtureDate)
            let parameters = try OptimizationParameters(species: .pichiaPastoris, startPolicy: .ifNotMethionine,
                                                        stopPolicy: .add, avoid: AvoidMotifs("TGCA"))
            let second = try store.createPreset(name: "Second", parameters: parameters, createdAt: fixtureDate + 1)
            #expect(first.name == "中文预设")
            #expect(try ProteinStore(url: url).presets() == [second, first])
            #expect(try store.deletePreset(id: first.id))
            #expect(try !store.deletePreset(id: first.id))
            #expect(try store.presets() == [second])
            for name in ["  ", String(repeating: "字", count: 81)] {
                #expect(throws: PersistenceError.invalidPresetName) { try store.createPreset(name: name, parameters: .init()) }
            }
        }
    }
}

let fixtureDate = Date(timeIntervalSinceReferenceDate: 123_456.123456)

func withTemporaryDatabase(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appendingPathComponent("store.sqlite"))
}

func sampleBatch(name: String = "Local snapshot", parameters: OptimizationParameters = .init()) throws -> Batch {
    try BatchPreparation.prepare(name: name, input: .records([
        .init(name: "first", sequence: "AA"), .init(name: "second", sequence: "M"),
    ]), parameters: parameters, requestID: "local-request", now: fixtureDate)
}

func sampleAttempt(_ number: Int, status: AttemptStatus = .failed, effect: RequestEffect = .notSubmitted) -> RequestAttempt {
    RequestAttempt(number: number, startedAt: fixtureDate, payloadSHA256: .hash("synthetic-payload-\(number)"),
                   status: status, effect: effect)
}
