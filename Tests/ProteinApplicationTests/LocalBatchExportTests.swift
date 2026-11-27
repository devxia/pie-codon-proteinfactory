import Foundation
import ProteinApplication
import ProteinDomain
import Testing
import ZIPFoundation

struct LocalBatchExportTests {
    @Test func auditContainsOriginalProteinAndMetadataWithoutSequenceResultsOrResponseBodies() throws {
        let input = String(repeating: "A", count: 81)
        var batch = try BatchPreparation.prepare(name: "Audit fixture", input: .records([
            .init(name: "蛋白 > first", sequence: input), .init(name: "Second", sequence: "MK*")
        ]), parameters: .init(startPolicy: .ifNotMethionine, stopPolicy: .add), requestID: "local-audit")
        batch.records[0].dna = "DNA fixture to omit"
        batch.records[0].dnaSHA256 = .hash("DNA fixture to omit")
        batch.records[0].checks = DNAChecks(basePairCount: 246, aminoAcidCount: 81, gcPercent: 60,
                                           hasTerminalStop: true, checkedMotifCount: 0)
        batch.records[0].attempts = [RequestAttempt(number: 1, startedAt: batch.createdAt, payloadSHA256: .hash("local"),
                                                    status: .failed, effect: .rejected,
                                                    response: Data("Response fixture to omit".utf8))]
        let fasta = try LocalBatchExport.data(for: batch, format: .inputFASTA)
        #expect(String(decoding: fasta, as: UTF8.self) == ">蛋白 _ first\n\(String(input.prefix(80)))\nA\n>Second\nMK*\n")

        let archive = try Archive(data: LocalBatchExport.data(for: batch, format: .auditZIP), accessMode: .read)
        #expect(archive.map(\.path) == ["job.json", "input.fasta", "README.txt"])
        #expect(try read("input.fasta", from: archive) == fasta)
        let readme = try read("README.txt", from: archive)
        #expect(String(decoding: readme, as: UTF8.self).hasPrefix("Codon ProteinFactory local batch audit\n"))
        let manifest = try read("job.json", from: archive)
        let text = String(decoding: manifest, as: UTF8.self)
        let root = try #require(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let records = try #require(root["records"] as? [[String: Any]])
        let first = try #require(records.first)
        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["startCodonPolicy"] as? String == "ifNotMethionine")
        #expect(first["originalProtein"] as? String == input)
        #expect(first["preparedProtein"] as? String == input + "*")
        #expect((first["checks"] as? [String: Any])?["basePairCount"] as? Int == 246)
        #expect((first["attempts"] as? [[String: Any]])?.first?["effect"] as? String == "rejected")
        #expect(first["dna"] == nil)
        #expect(!text.contains("DNA fixture to omit"))
        #expect(!text.contains(Data("Response fixture to omit".utf8).base64EncodedString()))
        #expect(!text.contains("Response fixture to omit"))
    }

    @Test func synthesisCSVExportsOnlyVerifiedResultsWithOriginalProteinAndContinuousNumbers() throws {
        var batch = try BatchPreparation.prepare(name: "三靶点", input: .records([
            .init(name: "样本, \"一\"", sequence: "A"),
            .init(name: "Pending", sequence: "M"),
            .init(name: "Bad checksum", sequence: "M"),
            .init(name: "Wrong translation", sequence: "M"),
            .init(name: "Last", sequence: "M")
        ]), parameters: .init(startPolicy: .ifNotMethionine, stopPolicy: .add))
        let dna = ["ATGGCTTAA", "ATGTAA", "ATGTAA", "GCTTAA", "ATGTAG"]
        for index in batch.records.indices {
            batch.records[index].dna = dna[index]
            batch.records[index].dnaSHA256 = .hash(dna[index])
            batch.records[index].status = .completed
        }
        batch.records[1].status = .pending
        batch.records[2].dnaSHA256 = .hash("mismatch")

        let output = try LocalBatchExport.data(for: batch, format: .synthesisCSV)
        let expected = [
            "Number,Name,Protein Sequence,Codon-Optimized DNA Sequence",
            "1,\"样本, \"\"一\"\"\",A,ATGGCTTAA",
            "2,Last,M,ATGTAG",
            ""
        ].joined(separator: "\r\n")
        #expect(output == Data(expected.utf8))
    }

    @Test func synthesisCSVReportsWhenNoResultsPassVerification() throws {
        var batch = try BatchPreparation.prepare(name: "CSV fixture", input: .text("M"))
        #expect(throws: LocalBatchExport.ExportError.noVerifiedResults) {
            try LocalBatchExport.data(for: batch, format: .synthesisCSV)
        }
        batch.records[0].status = .completed
        #expect(throws: LocalBatchExport.ExportError.noVerifiedResults) {
            try LocalBatchExport.data(for: batch, format: .synthesisCSV)
        }
    }

    @Test func atomicWritePreservesExistingDestinationWhenPayloadIsOversized() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let target = directory.appending(path: "audit.zip")
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try LocalBatchExport.write(original, to: target)
        #expect(throws: LocalBatchExport.ExportError.exceedsSizeLimit) {
            try LocalBatchExport.write(Data(count: 10 * 1_024 * 1_024 + 1), to: target)
        }
        #expect(try Data(contentsOf: target) == original)
        try LocalBatchExport.write(replacement, to: target)
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try files.contentsOfDirectory(atPath: directory.path) == ["audit.zip"])
    }

    private func read(_ member: String, from archive: Archive) throws -> Data {
        let entry = try #require(archive[member])
        var data = Data()
        let crc = try archive.extract(entry) { data.append($0) }
        #expect(crc == entry.checksum)
        return data
    }
}
