import Foundation
import ProteinApplication
import ProteinDomain
import ProteinPersistence
import Testing

/// Opt-in only: this test sends one non-sensitive test sequence to the real service.
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["PROTEIN_FACTORY_LIVE_SERVER_TEST"] == "1"),
    .timeLimit(.minutes(3))
)
struct LiveServerIntegrationTests {
    @Test func oneTestRecordPersistsVerifiedDNAFromRealService() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("protein-live-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("live.sqlite")
        let store = try ProteinStore(url: databaseURL)
        let queue = QueueCoordinator(store: store, settings: try QueueSettings(timeout: 120, intervalMilliseconds: 100))
        let draft = try BatchPreparation.prepare(
            name: "Live server integration",
            input: .records([.init(
                name: "native-live-smoke",
                sequence: "MKTAYIAKQRQISFVKSHFSRQ*"
            )])
        )

        try await queue.submit(.init(confirmed: draft))
        await queue.waitUntilIdle()

        let completed = try #require(try store.batch(id: draft.id))
        let record = try #require(completed.records.first)
        let attempt = try #require(record.attempts.first)
        let response = attempt.response.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
        print("""
        LIVE_SERVER_RESULT batch=\(completed.status.rawValue) record=\(record.status.rawValue) \
        http=\(attempt.httpStatus.map(String.init) ?? "none") dna=\(record.dna ?? "none") \
        response=\(response) error=\(record.error ?? completed.message)
        """)

        #expect(completed.status == .completed)
        #expect(record.status == .completed)
        #expect(record.attempts.count == 1)
        #expect(attempt.effect == .completed)
        #expect(attempt.httpStatus == 200)
        #expect(record.dna != nil)
        #expect(record.checks != nil)
        #expect(record.dnaSHA256 == record.dna.map { SHA256Digest.hash($0) })

        let reopened = try ProteinStore(url: databaseURL)
        #expect(try reopened.batch(id: draft.id)?.records.first?.dna == record.dna)
        #expect(try reopened.batch(id: draft.id)?.records.first?.checks == record.checks)
    }
}
