import ProteinApplication
import ProteinPersistence
import SwiftUI

struct BatchPreviewPage: View {
    let preview: ProteinImportPreview
    let store: ProteinStore?
    let queue: QueueCoordinator?
    let returnToEditing: () -> Void
    let didSave: (UUID) -> Void
    @State private var search = ""
    @State private var saving = false
    @State private var submitting = false
    @State private var confirmsSubmission = false
    @State private var issue: LocalizedStringResource?

    private var busy: Bool { saving || submitting }

    private var visibleRecords: [ProteinImportPreviewRecord] {
        guard !search.isEmpty else { return preview.records }
        return preview.records.filter {
            $0.name.localizedStandardContains(search)
                || $0.originalSequence.value.localizedCaseInsensitiveContains(search)
                || $0.submittedSequence.value.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(Text("batch.preview.title"), subtitle: Text(preview.batch.name)) {
                Button(action: returnToEditing) {
                    Label("batch.preview.edit", systemImage: "arrow.left")
                }
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(busy)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceStyle.gap) {
                    summary

                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                WorkspaceSectionTitle("batch.preview.records", icon: "list.bullet.rectangle")
                                Spacer(minLength: 16)
                                WorkspaceSearchField(title: "batch.preview.search", text: $search).frame(width: 230)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                WorkspaceSectionTitle("batch.preview.records", icon: "list.bullet.rectangle")
                                WorkspaceSearchField(title: "batch.preview.search", text: $search)
                            }
                        }
                        let filtered = visibleRecords
                        if filtered.isEmpty {
                            Label("batch.preview.noMatches", systemImage: "magnifyingglass")
                                .foregroundStyle(WorkspaceStyle.muted)
                                .padding(.vertical, 10)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(filtered, id: \.position) { record in
                                    previewRow(record)
                                }
                            }
                        }
                    }
                    .workspaceCard()
                }
                .padding(.horizontal, WorkspaceStyle.pageInset)
                .padding(.bottom, WorkspaceStyle.gap)
            }

            WorkspaceActionBar {
                VStack(alignment: .leading, spacing: 5) {
                    Label("batch.preview.local", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(WorkspaceStyle.muted)
                    if let issue { WorkspaceIssue(message: issue) }
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(submitting ? Text("batch.preview.submitting") : Text("batch.preview.saving"))
                }
                Button {
                    save()
                } label: {
                    Label("batch.preview.save", systemImage: "archivebox")
                }
                .controlSize(.large)
                .disabled(busy || store == nil)
                Button {
                    confirmsSubmission = true
                } label: {
                    Label("batch.preview.submit", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || queue == nil)
            }
        }
        .confirmationDialog("batch.submit.title", isPresented: $confirmsSubmission, titleVisibility: .visible) {
            Button("batch.preview.submit") { submit() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("batch.submit.message \(preview.recordCount)")
        }
    }

    private func save() {
        guard let store, !busy else { return }
        let batch = preview.batch
        saving = true
        issue = nil
        WorkspaceWrites.run {
            defer { saving = false }
            do {
                try await runInBackground {
                    if try !store.insertNewBatch(batch), try store.batch(id: batch.id, includingResponses: false) == nil {
                        throw PersistenceError.invalidRecordLayout
                    }
                }
                didSave(batch.id)
            } catch {
                issue = storageMessage(for: error)
            }
        }
    }

    private func submit() {
        guard let queue, !busy else { return }
        submitting = true
        issue = nil
        Task {
            defer { submitting = false }
            do {
                try await queue.submit(.init(confirmed: preview))
                didSave(preview.batch.id)
            } catch {
                issue = submissionMessage(for: error)
            }
        }
    }

    private var summary: some View {
        let addedStartCount = preview.records.count {
            preview.parameters.startPolicy.prependsATG(to: $0.submittedSequence)
        }
        let addedStopCount = preview.records.count {
            !$0.originalSequence.hasTerminalStop && $0.submittedSequence.hasTerminalStop
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: WorkspaceStyle.gap) {
                figure("batch.preview.count", value: preview.recordCount)
                figure("batch.preview.originalLength", value: preview.originalSequenceLength)
                figure("batch.preview.submittedLength", value: preview.submittedSequenceLength)
            }

            if addedStartCount > 0 {
                Label("batch.preview.startsAdded \(addedStartCount)", systemImage: "a.circle")
                    .font(.callout)
                    .foregroundStyle(WorkspaceStyle.text)
                    .workspaceCard(inset: 12)
            }

            if addedStopCount > 0 {
                Label("batch.preview.stopsAdded \(addedStopCount)", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(WorkspaceStyle.text)
                    .workspaceCard(inset: 12)
            }

            DisclosureGroup {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("batch.species").foregroundStyle(WorkspaceStyle.muted)
                        Text(preview.parameters.species.workspaceTitle)
                    }
                    GridRow {
                        Text("batch.start").foregroundStyle(WorkspaceStyle.muted)
                        Text(preview.parameters.startPolicy.workspaceTitle)
                    }
                    GridRow {
                        Text("batch.stop").foregroundStyle(WorkspaceStyle.muted)
                        Text(preview.parameters.stopPolicy.workspaceTitle)
                    }
                    GridRow {
                        Text("batch.motifs.final").foregroundStyle(WorkspaceStyle.muted)
                        MotifValue(motifs: preview.finalMotifs)
                    }
                    GridRow {
                        Text("batch.preview.recipient").foregroundStyle(WorkspaceStyle.muted)
                        Text(verbatim: preview.endpoint.absoluteString)
                            .font(WorkspaceStyle.sequenceFont)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .padding(.top, 10)
            } label: {
                WorkspaceSectionTitle("batch.preview.details", icon: "slider.horizontal.3")
            }
            .workspaceCard()
        }
    }

    private func figure(_ title: LocalizedStringResource, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.formatted())
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(WorkspaceStyle.text)
            Text(title).font(.callout).foregroundStyle(WorkspaceStyle.muted)
        }
        .workspaceCard()
        .accessibilityElement(children: .combine)
    }

    private func previewRow(_ record: ProteinImportPreviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceRule()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    Text(record.name).textSelection(.enabled)
                    SequenceValue(title: "batch.protein.original", sequence: record.originalSequence.value)
                    SequenceValue(title: "batch.protein.submitted", sequence: record.submittedSequence.value)
                }
                .padding(.top, 7)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(record.name).fontWeight(.medium).lineLimit(1).help(record.name)
                        Spacer()
                        Text(record.source.workspaceTitle).font(.caption).foregroundStyle(WorkspaceStyle.muted).monospacedDigit()
                        Text(stopStatus(record)).font(.caption).foregroundStyle(WorkspaceStyle.muted)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        sequenceSnippet("batch.protein.original", value: record.originalSequence.value)
                        sequenceSnippet("batch.protein.submitted", value: record.submittedSequence.value)
                    }
                }
            }
            .padding(.vertical, 9)
        }
    }

    private func sequenceSnippet(_ title: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(WorkspaceStyle.muted)
            Text(verbatim: value).font(WorkspaceStyle.sequenceFont).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stopStatus(_ record: ProteinImportPreviewRecord) -> LocalizedStringResource {
        if record.originalSequence.hasTerminalStop { return "batch.stop.existing" }
        return record.submittedSequence.hasTerminalStop ? "batch.stop.added" : "batch.stop.absent"
    }
}
