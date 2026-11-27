import ProteinApplication
import ProteinDomain
import ProteinPersistence
import SwiftUI

struct BatchHistoryPage: View {
    let store: ProteinStore
    let queue: QueueCoordinator?
    @Binding var selection: UUID?
    @State private var search = ""
    @State private var status: BatchStatus?
    @State private var entries: [BatchHistoryEntry] = []
    @State private var loading = true
    @State private var hasMore = false
    @State private var issue: LocalizedStringResource?
    @State private var revision = 0
    @State private var offset = 0
    private let pageSize = 50

    var body: some View {
        let query = HistoryQuery(search: search, status: status, revision: revision, offset: offset)
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(Text("history.title"))
            HSplitView {
                browserPane
                    .frame(minWidth: 245, idealWidth: 295, maxWidth: 375, maxHeight: .infinity)
                    .workspaceCard(inset: 0)
                    .padding(.trailing, 6)

                Group {
                    if let selection {
                        BatchHistoryDetail(id: selection, store: store, queue: queue) {
                            self.selection = nil
                            refresh()
                        }
                        .id(selection)
                    } else {
                        ContentUnavailableView("history.select", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .frame(minWidth: 385, maxWidth: .infinity, maxHeight: .infinity)
                .workspaceCard(inset: 0)
                .padding(.leading, 6)
            }
            .padding(.horizontal, WorkspaceStyle.pageInset)
            .padding(.bottom, WorkspaceStyle.pageInset)
        }
        .onChange(of: search) { _, _ in resetFilter() }
        .onChange(of: status) { _, _ in resetFilter() }
        .task(id: query) { await load(query) }
        .task(id: activeHistory) {
            guard !activeHistory.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    private var activeHistory: [BatchHistoryEntry] {
        entries.filter { $0.status == .queued || $0.status == .running }
    }

    private var browserPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceSearchField(title: "history.search", text: $search)
                Picker("history.filter", selection: $status) {
                    Text("history.all").tag(nil as BatchStatus?)
                    ForEach(BatchStatus.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            .padding(WorkspaceStyle.cardInset)
            WorkspaceRule()
            if let issue {
                VStack(alignment: .leading, spacing: 10) {
                    WorkspaceIssue(message: issue)
                    Button("history.refresh") { refresh() }
                }
                .padding(WorkspaceStyle.cardInset)
                Spacer(minLength: 0)
            } else if loading && offset == 0 {
                ProgressView("history.loading").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView(search.isEmpty && status == nil ? "history.empty" : "history.noMatches", systemImage: "archivebox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, selection: $selection) { entry in
                    HistoryRow(entry: entry).tag(entry.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if hasMore {
                Button("history.more") { offset = entries.count }
                    .disabled(loading)
                    .padding(WorkspaceStyle.cardInset)
            }
        }
    }

    private func resetFilter() {
        selection = nil
        offset = 0
        entries = []
        hasMore = false
        loading = true
    }

    private func refresh() {
        offset = 0
        hasMore = false
        revision += 1
    }

    private func load(_ query: HistoryQuery) async {
        loading = entries.isEmpty || query.offset > 0
        issue = nil
        do {
            if query.offset == 0 && !query.search.isEmpty { try await Task.sleep(for: .milliseconds(160)) }
            let page = try await runInBackground {
                try store.batchHistory(nameContaining: query.search, status: query.status, limit: pageSize + 1, offset: query.offset)
            }
            guard !Task.isCancelled else { return }
            let visible = page.prefix(pageSize)
            if query.offset == 0 { entries = Array(visible) }
            else { entries.append(contentsOf: visible) }
            hasMore = page.count > pageSize
        } catch {
            guard !Task.isCancelled else { return }
            issue = storageMessage(for: error)
        }
        loading = false
    }

    private struct HistoryQuery: Equatable, Sendable {
        let search: String
        let status: BatchStatus?
        let revision: Int
        let offset: Int
    }
}

private struct HistoryRow: View {
    let entry: BatchHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.name).font(WorkspaceStyle.sectionTitle).lineLimit(2).help(entry.name)
            ViewThatFits(in: .horizontal) {
                HStack {
                    status
                    Spacer(minLength: 8)
                    date
                }
                VStack(alignment: .leading, spacing: 4) {
                    status
                    date
                }
            }
            Text("history.summary \(entry.completedCount) \(entry.failedCount) \(entry.unknownCount) \(entry.recordCount)")
                .font(.caption).monospacedDigit()
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        Label(entry.status.title, systemImage: entry.status.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var date: some View {
        Text(entry.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
    }
}

extension BatchStatus {
    var title: LocalizedStringResource {
        switch self {
        case .prepared: "status.prepared"
        case .queued: "status.queued"
        case .running: "status.running"
        case .completed: "status.completed"
        case .partial: "status.partial"
        case .failed: "status.failed"
        case .stopped: "status.stopped"
        case .unknown: "status.unknown"
        }
    }

    var icon: String {
        switch self {
        case .prepared: "doc"
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .failed: "xmark.circle"
        case .stopped: "stop.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

extension RecordStatus {
    var title: LocalizedStringResource {
        switch self {
        case .pending: "status.pending"
        case .running: BatchStatus.running.title
        case .completed: BatchStatus.completed.title
        case .failed: BatchStatus.failed.title
        case .unknown: BatchStatus.unknown.title
        }
    }
}

extension AttemptStatus {
    var title: LocalizedStringResource {
        switch self {
        case .dispatching: "status.dispatching"
        case .completed: BatchStatus.completed.title
        case .failed: BatchStatus.failed.title
        case .unknown: BatchStatus.unknown.title
        }
    }
}

extension RequestEffect {
    var title: LocalizedStringResource {
        switch self {
        case .unknown: BatchStatus.unknown.title
        case .completed: BatchStatus.completed.title
        case .rejected: "status.rejected"
        case .notSubmitted: "status.notSubmitted"
        }
    }
}
