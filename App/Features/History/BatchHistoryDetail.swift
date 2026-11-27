import AppKit
import ProteinApplication
import ProteinDomain
import ProteinPersistence
import SwiftUI
import UniformTypeIdentifiers

struct BatchHistoryDetail: View {
    let id: UUID
    let store: ProteinStore
    let queue: QueueCoordinator?
    let didDelete: () -> Void
    @State private var batch: Batch?
    @State private var loaded = false
    @State private var recordStatus: RecordStatus?
    @State private var selectedRecord: UUID?
    @State private var issue: LocalizedStringResource?
    @State private var feedback: LocalizedStringResource?
    @State private var busy = false
    @State private var confirmsDeletion = false
    @State private var confirmsSubmission = false

    var body: some View {
        Group {
            if let batch {
                batchDetail(batch)
            } else if let issue {
                ContentUnavailableView {
                    Label(issue, systemImage: "exclamationmark.circle")
                } actions: {
                    Button("history.refresh") { Task { await load() } }
                }
            } else if loaded {
                ContentUnavailableView("history.missing", systemImage: "doc.questionmark")
            } else {
                ProgressView("history.loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .task(id: batch?.status) {
            guard batch?.status == .queued || batch?.status == .running else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
        .confirmationDialog("batch.submit.title", isPresented: $confirmsSubmission, titleVisibility: .visible) {
            Button("batch.preview.submit") {
                if let batch { submit(batch) }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            if let batch {
                Text("batch.submit.message \(batch.records.count)")
            }
        }
        .confirmationDialog("history.delete.title", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("history.delete", role: .destructive) { delete() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("history.delete.message")
        }
    }

    private func batchDetail(_ batch: Batch) -> some View {
        let records = batch.records.filter { recordStatus == nil || $0.status == recordStatus }
        let selected = records.first { $0.id == selectedRecord }
        let summary = BatchSummary(statuses: batch.records.map(\.status))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(batch.name).font(.title2.weight(.semibold)).lineLimit(2).help(batch.name)
                        .foregroundStyle(WorkspaceStyle.text)
                        .accessibilityAddTraits(.isHeader)
                    Label(batch.status.title, systemImage: batch.status.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WorkspaceStyle.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(WorkspaceStyle.accentBackground, in: .capsule)
                    Text("history.summary \(summary.completed) \(summary.failed) \(summary.unknown) \(batch.records.count)")
                        .font(.callout).monospacedDigit().foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 0)
                if batch.status == .prepared {
                    Button {
                        confirmsSubmission = true
                    } label: {
                        Label("history.submit", systemImage: "paperplane")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || queue == nil)
                }
                Menu {
                    Button("history.export.fasta") { export(batch, format: .inputFASTA) }
                    Button("history.export.synthesis") { export(batch, format: .synthesisCSV) }
                        .disabled(summary.completed == 0)
                    Button("history.export.audit") { export(batch, format: .auditZIP) }
                    Divider()
                    Button("history.delete", role: .destructive) { confirmsDeletion = true }
                        .disabled(batch.status == .running || batch.status == .queued)
                } label: {
                    Label("history.actions", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                .disabled(busy)
            }
            .padding(WorkspaceStyle.cardInset)
            if let issue { WorkspaceIssue(message: issue).padding(.horizontal, WorkspaceStyle.cardInset).padding(.bottom, 8) }
            if let feedback { Text(feedback).font(.callout).padding(.horizontal, WorkspaceStyle.cardInset).padding(.bottom, 8) }
            if batch.status == .prepared {
                Label("history.prepared.local", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(WorkspaceStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, WorkspaceStyle.cardInset)
                    .padding(.bottom, 8)
            }
            if !batch.message.isEmpty {
                Text(verbatim: batch.message).font(.callout).foregroundStyle(WorkspaceStyle.muted).textSelection(.enabled)
                    .padding(.horizontal, WorkspaceStyle.cardInset).padding(.bottom, 8)
            }
            WorkspaceRule()

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceStyle.gap) {
                    DisclosureGroup("batch.parameters") { metadata(batch) }
                    WorkspaceRule()
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            WorkspaceSectionTitle("history.records", icon: "list.bullet.rectangle")
                            Spacer(minLength: 12)
                            recordFilter.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            WorkspaceSectionTitle("history.records", icon: "list.bullet.rectangle")
                            recordFilter
                        }
                    }
                    if records.isEmpty {
                        Label("history.records.empty", systemImage: "list.bullet").foregroundStyle(WorkspaceStyle.muted)
                    } else {
                        List(records, selection: $selectedRecord) { record in
                            HStack {
                                Text(record.position.formatted()).monospacedDigit()
                                Text(record.name).fontWeight(.medium).lineLimit(1).help(record.name)
                                Spacer()
                                Text(record.status.title).font(.caption)
                            }
                            .accessibilityElement(children: .combine)
                            .tag(record.id)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .frame(height: min(166, CGFloat(records.count) * 29 + 14))
                        .workspaceField()
                        .accessibilityLabel(Text("history.records"))
                    }
                    if let selected {
                        RecordInspection(record: selected, parameters: batch.parameters, store: store).id(selected.id)
                    }
                }
                .padding(WorkspaceStyle.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: recordStatus) { _, _ in
            selectedRecord = records.first?.id
        }
    }

    private var recordFilter: some View {
        Picker("history.record.filter", selection: $recordStatus) {
            Text("history.all").tag(nil as RecordStatus?)
            ForEach(RecordStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
        }
    }

    private func metadata(_ batch: Batch) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("batch.species").foregroundStyle(.secondary)
                Text(batch.parameters.species.workspaceTitle)
            }
            GridRow {
                Text("batch.start").foregroundStyle(.secondary)
                Text(batch.parameters.startPolicy.workspaceTitle)
            }
            GridRow {
                Text("batch.stop").foregroundStyle(.secondary)
                Text(batch.parameters.stopPolicy.workspaceTitle)
            }
            GridRow {
                Text("batch.motifs.final").foregroundStyle(.secondary)
                MotifValue(motifs: batch.parameters.avoid.motifs)
            }
            GridRow {
                Text("history.updated").foregroundStyle(.secondary)
                Text(batch.updatedAt.formatted(date: .abbreviated, time: .standard))
            }
            if let authorized = batch.authorizedAt {
                GridRow {
                    Text("history.authorized").foregroundStyle(.secondary)
                    Text(authorized.formatted(date: .abbreviated, time: .standard))
                }
                GridRow {
                    Text("batch.preview.recipient").foregroundStyle(.secondary)
                    Text(verbatim: batch.endpoint.absoluteString).textSelection(.enabled)
                }
            }
        }
        .padding(.top, 8)
        .font(.callout)
    }

    private func load() async {
        issue = nil
        do {
            let result = try await runInBackground { try store.batch(id: id, includingResponses: false) }
            guard !Task.isCancelled else { return }
            batch = result
            if let result, !result.records.contains(where: { $0.id == selectedRecord }) {
                selectedRecord = result.records.first?.id
            }
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            issue = storageMessage(for: error)
        }
    }

    private func submit(_ batch: Batch) {
        guard let queue, !busy else { return }
        busy = true
        issue = nil
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await queue.submit(.init(confirmed: batch))
                await load()
            } catch {
                issue = submissionMessage(for: error)
            }
        }
    }

    private func delete() {
        guard !busy else { return }
        busy = true
        issue = nil
        feedback = nil
        WorkspaceWrites.run {
            defer { busy = false }
            do {
                if try await runInBackground({ try store.deleteInactiveBatch(id: id) }) {
                    didDelete()
                } else {
                    issue = "history.delete.unavailable"
                }
            } catch {
                issue = storageMessage(for: error)
            }
        }
    }

    private func export(_ batch: Batch, format: LocalBatchExport.Format) {
        guard !busy else { return }
        issue = nil
        feedback = nil
        busy = true
        let panel = NSSavePanel()
        let prohibited = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let name = batch.name.components(separatedBy: prohibited).joined(separator: "_")
        switch format {
        case .inputFASTA:
            // The save panel adds the extension from the allowed content type.
            let stem = name.prefix(120)
            let hasExtension = stem.lowercased().hasSuffix(".faa") && stem.count > 4
            panel.nameFieldStringValue = hasExtension ? String(stem.dropLast(4)) : String(stem)
            panel.allowedContentTypes = [UTType(filenameExtension: "faa") ?? .data]
        case .synthesisCSV:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
            let date = formatter.string(from: Date())
            panel.nameFieldStringValue = String(localized: "history.export.synthesis.filename \(name) \(date)")
            panel.allowedContentTypes = [.commaSeparatedText]
        case .auditZIP:
            panel.nameFieldStringValue = "\(name.prefix(120)).zip"
            panel.allowedContentTypes = [.zip]
        }
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else {
                busy = false
                return
            }
            WorkspaceWrites.run {
                defer { busy = false }
                do {
                    try await runInBackground {
                        let bytes = try LocalBatchExport.data(for: batch, format: format)
                        try LocalBatchExport.write(bytes, to: url)
                    }
                    feedback = "history.export.saved \(url.lastPathComponent)"
                } catch {
                    issue = exportMessage(for: error)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func exportMessage(for error: any Error) -> LocalizedStringResource {
        switch error {
        case LocalBatchExport.ExportError.exceedsSizeLimit: "history.export.size"
        case LocalBatchExport.ExportError.noVerifiedResults: "history.export.synthesis.empty"
        case CocoaError.fileWriteNoPermission, CocoaError.fileWriteVolumeReadOnly: "history.export.permission"
        case CocoaError.fileWriteOutOfSpace: "history.export.disk"
        default: "history.export.failed"
        }
    }
}
