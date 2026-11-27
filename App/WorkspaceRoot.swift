import AppKit
import ProteinApplication
import ProteinPersistence
import SwiftUI

struct WorkspaceRoot: View {
    @Binding var showsFilePicker: Bool
    @State private var page: Page = .newBatch
    @State private var store: ProteinStore?
    @State private var queue: QueueCoordinator?
    @State private var openingIssue: LocalizedStringResource?
    @State private var openRequest = 0
    @State private var selectedBatch: UUID?
    @State private var preset: ParameterPreset?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(WorkspaceStyle.border).frame(width: 1).accessibilityHidden(true)
            ZStack {
                let editing = page == .newBatch
                BatchWorkspace(showsFilePicker: $showsFilePicker, preset: $preset, store: store, queue: queue) { batchID in
                    selectedBatch = batchID
                    page = .history
                }
                .opacity(editing ? 1 : 0)
                .allowsHitTesting(editing)
                .accessibilityHidden(!editing)
                .disabled(!editing)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if editing, store == nil, let openingIssue {
                        HStack {
                            WorkspaceIssue(message: openingIssue)
                            Spacer()
                            Button("storage.reopen") { reopen() }
                        }
                        .padding(WorkspaceStyle.pageInset)
                        .background(WorkspaceStyle.surface)
                    }
                }

                switch page {
                case .history:
                    if let store { BatchHistoryPage(store: store, queue: queue, selection: $selectedBatch) }
                    else { storageStatus }
                case .presets:
                    if let store {
                        ParameterPresetsPage(store: store) { item in
                            preset = item
                            page = .newBatch
                        }
                    } else {
                        storageStatus
                    }
                case .settings:
                    WorkspaceSettingsPage(directory: WorkspaceStorage.directory)
                case .newBatch:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceStyle.pageBackground)
        }
        .tint(WorkspaceStyle.accent)
        .onChange(of: page) { _, _ in _ = NSApp.keyWindow?.makeFirstResponder(nil) }
        .onChange(of: showsFilePicker) { _, open in
            if open { page = .newBatch }
        }
        .task(id: openRequest) {
            do {
                let location = WorkspaceStorage.directory
                let opened = try await runInBackground { try WorkspaceStorage.open(in: location) }
                let coordinator = QueueCoordinator(store: opened, settings: try QueueSettings())
                guard !Task.isCancelled else { return }
                store = opened
                queue = coordinator
                WorkspaceWrites.registerQueue(coordinator)
            } catch {
                guard !Task.isCancelled else { return }
                openingIssue = storageMessage(for: error)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                Text(verbatim: CodonProteinFactoryApp.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.text)
                    .lineLimit(2)
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 20)

            ForEach(Page.allCases) { item in
                if item == .settings {
                    WorkspaceRule().padding(.vertical, 9)
                }
                Button {
                    page = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 19)
                            .foregroundStyle(page == item ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                            .accessibilityHidden(true)
                        Text(item.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: page == item ? .semibold : .medium))
                    .foregroundStyle(WorkspaceStyle.text)
                    .padding(.horizontal, 10)
                    .frame(height: 39)
                    .background(page == item ? WorkspaceStyle.accentBackground : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(WorkspaceNavigationButton())
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .frame(width: 194)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceStyle.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("workspace.navigation"))
    }

    @ViewBuilder private var storageStatus: some View {
        if let openingIssue {
            ContentUnavailableView {
                Label("storage.unavailable", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text(openingIssue)
            } actions: {
                Button("storage.reopen") { reopen() }
                Button("settings.finder") { NSWorkspace.shared.open(WorkspaceStorage.directory) }
            }
        } else {
            ProgressView("storage.opening")
        }
    }

    private func reopen() {
        openingIssue = nil
        openRequest += 1
    }

    private enum Page: String, Identifiable, CaseIterable {
        case newBatch, history, presets, settings
        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .newBatch: "batch.title"
            case .history: "history.title"
            case .presets: "presets.title"
            case .settings: "settings.title"
            }
        }

        var icon: String {
            switch self {
            case .newBatch: "square.and.pencil"
            case .history: "archivebox"
            case .presets: "slider.horizontal.3"
            case .settings: "gearshape"
            }
        }
    }
}

private struct WorkspaceNavigationButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

enum WorkspaceStorage {
    static var directory: URL {
        #if DEBUG
        if let directory = AppSmokeTest.workspaceDirectory { return directory }
        #endif
        // Keep the existing workspace path so the renamed app opens the same database.
        return URL.applicationSupportDirectory.appending(path: "Code ProteinFactory", directoryHint: .isDirectory)
    }

    static func open(in directory: URL) throws -> ProteinStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ProteinStore(url: directory.appending(path: "Workspace.sqlite"))
    }
}

func submissionMessage(for error: any Error) -> LocalizedStringResource {
    switch error {
    case QueueError.capacityReached: "queue.capacity"
    case QueueError.duplicateSubmission: "queue.duplicate"
    case QueueError.invalidPreparedBatch: "queue.invalidPrepared"
    case QueueError.closed: "queue.closed"
    case QueueError.storageFailure: "queue.storage"
    default: "queue.submit.failed"
    }
}

func storageMessage(for error: any Error) -> LocalizedStringResource {
    switch error {
    case PersistenceError.corruptedDatabase: "storage.corrupt"
    case PersistenceError.incompatibleSchema, PersistenceError.unsupportedSchemaVersion: "storage.schema"
    case PersistenceError.migrationFailed: "storage.migration"
    case PersistenceError.recoveryFailed: "storage.recovery"
    default: "storage.failed"
    }
}
