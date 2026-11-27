#if DEBUG
import AppKit
import ProteinApplication
import ProteinDomain
import ProteinPersistence
import SwiftUI

@MainActor
enum AppSmokeTest {
    static var isRequested: Bool { resultDirectory != nil }

    nonisolated static var workspaceDirectory: URL? {
        resultDirectory?.appending(path: "Workspace", directoryHint: .isDirectory)
            ?? directory(for: "--ui-test-workspace")
    }

    private nonisolated static let resultDirectory = directory(for: "--smoke-test")

    private nonisolated static func directory(for flag: String) -> URL? {
        let arguments = CommandLine.arguments
        guard let option = arguments.firstIndex(of: flag),
              arguments.indices.contains(option + 1) else { return nil }
        return URL(fileURLWithPath: arguments[option + 1], isDirectory: true)
    }

    static func startDeadline() {
        guard let resultDirectory else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            finish("FAIL The application window did not become visible in time.", in: resultDirectory, exitCode: 1)
        }
    }

    struct WindowProbe: NSViewRepresentable {
        func makeNSView(context: Context) -> ProbeView { ProbeView() }
        func updateNSView(_ nsView: ProbeView, context: Context) {}
    }

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { checkVisibility() }
        }

        private func checkVisibility() {
            guard let window else { return }
            if window.isVisible {
                AppSmokeTest.checkResources()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.checkVisibility()
                }
            }
        }
    }

    private static func checkResources() {
        guard let resultDirectory else { return }
        do {
            let bundle = Bundle.main
            guard bundle.bundleURL.pathExtension == "app",
                  let icon = bundle.url(forResource: "AppIcon", withExtension: "icns"),
                  NSImage(contentsOf: icon) != nil,
                  bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil,
                  bundle.url(forResource: "ZIPFoundation-LICENSE", withExtension: "txt") != nil else {
                throw CheckFailure.missingBundleResources
            }

            try checkLocalizations(in: bundle)

            let files = FileManager.default
            let directory = files.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: directory) }
            let testFile = directory.appending(path: "sample.csv")
            let sample = Data("item,sequence\n\"sample\nname\",AC\nnext,AX\n".utf8)
            try sample.write(to: testFile, options: .atomic)
            let inspection = try SpreadsheetInspection(url: testFile)
            guard let sheet = inspection.spreadsheet.sheets.first,
                  sheet.rows == [["item", "sequence"], ["sample\nname", "AC"], ["next", "AX"]],
                  sheet.sourceRows == [1, 2, 4] else {
                throw CheckFailure.temporaryDataMismatch
            }
            let mapped = try ProteinImport.read(spreadsheet: inspection.spreadsheet, mapping: .init(
                worksheetIndex: 0, firstRowIsHeader: true, nameColumn: 0, sequenceColumn: 1
            ))
            let mappedCheck = try ProteinImport.validate(mapped)
            guard mappedCheck.records.map(\.record.source.sourceRow) == [2, 4],
                  mappedCheck.records.map(\.issues) == [[.input(.invalidName)], [.input(.sequence(.invalidResidue(position: 2)))]] else {
                throw CheckFailure.spreadsheetMappingMismatch
            }

            let paste = ValidationInput.paste(">first\nac d\n>second\nmk*\n")
            let parameters = OptimizationParameters(stopPolicy: .add, avoid: try AvoidMotifs("GAATTC,GGT(A/T)ACC", enzymes: [.ecoRI]))
            let pasteCheck = try paste.validate(parameters: parameters)
            let pastePreview = try ProteinImport.prepare(name: "Smoke Paste", validation: pasteCheck)
            guard pastePreview.recordCount == 2, pastePreview.originalSequenceLength == 6,
                  pastePreview.submittedSequenceLength == 7, pastePreview.finalMotifs == ["GAATTC", "GGTAACC", "GGTTACC"],
                  pastePreview.records.map(\.source) == [.paste(line: 1), .paste(line: 3)],
                  pastePreview.records.map(\.submittedSequence.value) == ["ACD*", "MK*"],
                  pastePreview.endpoint == Batch.serviceEndpoint else { throw CheckFailure.pastePreviewMismatch }

            let fastaURL = directory.appending(path: "sample.faa")
            try Data(">one\nAC\n\n>two\nMK\n".utf8).write(to: fastaURL, options: .atomic)
            guard case let .fasta(fastaFile) = try BatchFile.read(url: fastaURL, mode: .fasta) else {
                throw CheckFailure.fastaPreviewMismatch
            }
            let fastaCheck = try ValidationInput.fasta(fastaFile).validate(parameters: .init())
            let fastaPreview = try ProteinImport.prepare(name: "Smoke FASTA", validation: fastaCheck)
            guard fastaPreview.records.map(\.source) == [.fasta(line: 1), .fasta(line: 4)],
                  fastaPreview.records.map(\.submittedSequence.value) == ["AC", "MK"] else {
                throw CheckFailure.fastaPreviewMismatch
            }
            let timings = try checkWorkspace(pastePreview, in: directory)
            finish("PASS Window, resources, CSV mapping, pasted and FASTA previews, local history, presets and audit export verified. \(timings)",
                   in: resultDirectory, exitCode: 0)
        } catch {
            finish("FAIL \(error)", in: resultDirectory, exitCode: 1)
        }
    }

    private static func checkWorkspace(_ preview: ProteinImportPreview, in directory: URL) throws -> String {
        let workspace = directory.appending(path: "Persistence", directoryHint: .isDirectory)
        let preset = try saveWorkspaceFixture(preview, in: workspace)
        let store = try WorkspaceStorage.open(in: workspace)
        guard let restored = try store.batch(id: preview.batch.id), restored.fingerprint == preview.fingerprint,
              restored.status == .prepared, restored.authorizedAt == nil,
              try store.presets() == [preset] else { throw CheckFailure.workspaceMismatch }
        let destination = directory.appending(path: "local-audit.zip")
        let audit = try LocalBatchExport.data(for: restored, format: .auditZIP)
        try LocalBatchExport.write(audit, to: destination)
        guard try Data(contentsOf: destination) == audit else { throw CheckFailure.workspaceMismatch }

        let clock = ContinuousClock()
        let residue = String(repeating: "A", count: 1_000)
        let input = (1...200).map { ">record-\($0)\n\(residue)" }.joined(separator: "\n")
        let start = clock.now
        let validation = try ValidationInput.paste(input).validate(parameters: .init())
        let large = try ProteinImport.prepare(name: "Large workspace fixture", validation: validation)
        let importTime = start.duration(to: clock.now)
        guard large.recordCount == 200, large.originalSequenceLength == 200_000,
              try store.insertNewBatch(large.batch) else { throw CheckFailure.workspaceMismatch }

        for index in 1...998 {
            let batch = try BatchPreparation.prepare(name: "History \(index)", input: .text(">record\nAC"),
                                                     requestID: "smoke-\(index)")
            guard try store.insertNewBatch(batch) else { throw CheckFailure.workspaceMismatch }
        }
        let historyStart = clock.now
        let firstPage = try store.batchHistory(limit: 51)
        let historyTime = historyStart.duration(to: clock.now)
        guard firstPage.count == 51 else { throw CheckFailure.workspaceMismatch }

        let protein = try ProteinSequence(String(repeating: "A", count: 10_000))
        let dna = String(repeating: "GCT", count: 10_000)
        let compareStart = clock.now
        let codons = try DNAValidation.compareCodons(dna, with: protein)
        let compareTime = compareStart.duration(to: clock.now)
        guard codons.count == 10_000, codons.last?.translated == "A" else { throw CheckFailure.workspaceMismatch }
        return "Debug timings, 200-record preparation \(importTime), 1,000-batch first page \(historyTime), 10,000-codon comparison \(compareTime)."
    }

    private static func saveWorkspaceFixture(_ preview: ProteinImportPreview, in directory: URL) throws -> ParameterPreset {
        let store = try WorkspaceStorage.open(in: directory)
        guard try store.insertNewBatch(preview.batch), try !store.insertNewBatch(preview.batch) else {
            throw CheckFailure.workspaceMismatch
        }
        return try store.createPreset(name: "Local preset", parameters: preview.parameters)
    }

    private static func checkLocalizations(in bundle: Bundle) throws {
        guard let resources = bundle.resourceURL else { throw CheckFailure.missingBundleResources }
        var keys: Set<String>?
        for language in ["en", "zh-Hans"] {
            let tableURL = resources.appending(path: "\(language).lproj/Localizable.strings")
            let data = try Data(contentsOf: tableURL)
            guard let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  ["spreadsheet.preview", "batch.title", "batch.prepare", "batch.preview.save", "history.title", "history.export.audit",
                   "presets.title", "settings.title", "storage.unavailable"]
                    .allSatisfy({ strings[$0]?.isEmpty == false }),
                  strings.values.allSatisfy({ !$0.isEmpty }),
                  keys == nil || keys == Set(strings.keys) else {
                throw CheckFailure.invalidLocalization(language)
            }
            keys = Set(strings.keys)
        }
    }

    private nonisolated static func finish(_ result: String, in directory: URL, exitCode: Int32) -> Never {
        do {
            try (result + "\n").write(to: directory.appending(path: "result"), atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Unable to write the smoke test result.\n".utf8))
            exit(1)
        }
        exit(exitCode)
    }

    private enum CheckFailure: Error {
        case missingBundleResources
        case invalidLocalization(String)
        case temporaryDataMismatch
        case spreadsheetMappingMismatch
        case pastePreviewMismatch
        case fastaPreviewMismatch
        case workspaceMismatch
    }
}
#endif
