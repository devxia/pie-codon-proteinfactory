import Foundation
import GRDB
import ProteinDomain
import ProteinPersistence
import Testing

struct StartupRecoveryTests {
    @Test func restartMarksDispatchUnknownAndStopsUnstartedQueueWithoutNewAttempts() throws {
        try withTemporaryDatabase { url in
            var active = try sampleBatch(name: "Interrupted dispatch")
            active.status = .running
            active.authorizedAt = fixtureDate
            active.records[0].status = .running
            let earlier = sampleAttempt(1)
            let dispatched = sampleAttempt(2, status: .dispatching, effect: .unknown)
            active.records[0].attempts = [earlier, dispatched]
            var queued = try sampleBatch(name: "Not started")
            queued.status = .queued
            queued.authorizedAt = fixtureDate
            let prepared = try sampleBatch(name: "No consent yet")
            do {
                let store = try ProteinStore(url: url)
                for batch in [active, queued, prepared] { try store.saveBatch(batch) }
            }

            let recoveredAt = fixtureDate + 500
            func assertRecovery(at openDate: Date) throws {
                let store = try ProteinStore(url: url, recoveringAt: openDate)
                let recovered = try #require(try store.batch(id: active.id))
                #expect(recovered.status == .unknown)
                #expect(recovered.updatedAt == recoveredAt)
                #expect(recovered.authorizedAt == active.authorizedAt)
                #expect(recovered.records.map(\.status) == [.unknown, .pending])
                var unknown = dispatched
                unknown.status = .unknown
                #expect(recovered.records[0].attempts == [earlier, unknown])
                #expect(recovered.records[1] == active.records[1])
                let stopped = try #require(try store.batch(id: queued.id))
                #expect(stopped.status == .stopped)
                #expect(stopped.updatedAt == recoveredAt)
                #expect(stopped.authorizedAt == queued.authorizedAt)
                #expect(stopped.records == queued.records)
                #expect(try store.batch(id: prepared.id) == prepared)
            }
            try assertRecovery(at: recoveredAt)
            try assertRecovery(at: recoveredAt + 1)
        }
    }

    @Test func recoveryHandlesInconsistentDispatchAndInterruptedBatchTransitions() throws {
        try withTemporaryDatabase { url in
            var pendingDispatch = try sampleBatch(name: "Dispatch intent is stronger than stale record state")
            pendingDispatch.status = .queued
            pendingDispatch.records[0].attempts = [sampleAttempt(1, status: .dispatching, effect: .unknown)]
            var runningWithoutAttempt = try sampleBatch(name: "No related attempt row")
            runningWithoutAttempt.status = .running
            runningWithoutAttempt.records[0].status = .running
            var waiting = try sampleBatch(name: "No dispatch yet")
            waiting.status = .running
            var received = try sampleBatch(name: "Receipts committed before exit")
            received.status = .running
            received.records[0].status = .completed
            received.records[1].status = .failed
            do {
                let store = try ProteinStore(url: url)
                for batch in [pendingDispatch, runningWithoutAttempt, waiting, received] { try store.saveBatch(batch) }
            }
            let recovered = try ProteinStore(url: url)
            let first = try #require(try recovered.batch(id: pendingDispatch.id))
            #expect(first.status == .unknown)
            #expect(first.records.map(\.status) == [.unknown, .pending])
            #expect(first.records[0].attempts.map(\.status) == [.unknown])
            let second = try #require(try recovered.batch(id: runningWithoutAttempt.id))
            #expect(second.status == .unknown)
            #expect(second.records.map(\.status) == [.unknown, .pending])
            #expect(second.records.allSatisfy { $0.attempts.isEmpty })
            #expect(try recovered.batch(id: waiting.id)?.status == .stopped)
            #expect(try recovered.batch(id: waiting.id)?.records == waiting.records)
            #expect(try recovered.batch(id: received.id)?.status == .partial)
            #expect(try recovered.batch(id: received.id)?.records == received.records)
        }
    }

    @Test func recoveryKeepsTerminalAuditReceiptWhenNoNewAttemptWasDispatched() throws {
        try withTemporaryDatabase { url in
            var batch = try sampleBatch()
            batch.status = .running
            batch.records[0].status = .failed
            var receipt = sampleAttempt(1, status: .failed, effect: .rejected)
            receipt.finishedAt = fixtureDate + 1
            receipt.httpStatus = 400
            receipt.error = "Bad request"
            batch.records[0].attempts = [receipt]
            do {
                let store = try ProteinStore(url: url)
                try store.saveBatch(batch)
                var running = batch.records[0]
                running.status = .running
                running.attempts = []
                try store.saveRecord(running)
            }

            let reopened = try ProteinStore(url: url, recoveringAt: fixtureDate + 2)
            let recovered = try #require(try reopened.batch(id: batch.id))
            #expect(recovered.status == .unknown)
            #expect(recovered.records[0].status == .unknown)
            #expect(recovered.records[0].attempts == [receipt])
        }
    }

    @Test func abortingHalfwayThroughReceiptRollsBackStatusAndRecoversLastDurableDispatch() throws {
        try withTemporaryDatabase { url in
            let batch = try sampleBatch()
            var active = batch
            active.status = .running
            active.updatedAt = fixtureDate + 1
            var record = batch.records[0]
            let dispatched = sampleAttempt(1, status: .dispatching, effect: .unknown)
            record.status = .running
            record.attempts = [dispatched]
            do {
                let store = try ProteinStore(url: url)
                try store.saveBatch(batch)
                try store.saveAttempt(dispatched, updatingRecord: record, updatingBatch: active)
                let sql = try DatabaseQueue(path: url.path)
                try sql.write { db in
                    try db.execute(sql: """
                        CREATE TRIGGER simulate_receipt_failure BEFORE UPDATE OF status ON attempts
                        WHEN NEW.status = 'completed'
                        BEGIN
                            SELECT CASE WHEN (SELECT status FROM records WHERE id = NEW.record_id) = 'completed'
                                THEN RAISE(ABORT, 'receipt write interrupted after record update')
                                ELSE RAISE(ABORT, 'record write missing') END;
                        END;
                        """)
                }

                var completed = record
                completed.status = .completed
                completed.dna = "GCTGCT"
                completed.dnaSHA256 = .hash("GCTGCT")
                completed.attempts[0].status = .completed
                completed.attempts[0].effect = .completed
                completed.attempts[0].httpStatus = 200
                completed.attempts[0].response = Data([42])
                var updated = active
                updated.status = .stopped
                updated.updatedAt = fixtureDate + 2
                do {
                    try store.saveAttempt(completed.attempts[0], updatingRecord: completed, updatingBatch: updated)
                    Issue.record("The failure trigger did not fire")
                } catch let error as DatabaseError {
                    #expect(error.message == "receipt write interrupted after record update")
                }
                #expect(try store.record(id: record.id) == record)
                #expect(try store.batch(id: batch.id)?.status == .running)
                #expect(try store.batch(id: batch.id)?.updatedAt == active.updatedAt)
            }

            let reopened = try ProteinStore(url: url, recoveringAt: fixtureDate + 3)
            let recovered = try #require(try reopened.batch(id: batch.id))
            #expect(recovered.status == .unknown)
            #expect(recovered.records[0].status == .unknown)
            #expect(recovered.records[0].dna == nil)
            #expect(recovered.records[0].dnaSHA256 == nil)
            var unknown = dispatched
            unknown.status = .unknown
            #expect(recovered.records[0].attempts == [unknown])
            #expect(recovered.records[1] == batch.records[1])
        }
    }
}
