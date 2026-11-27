import ProteinDomain
import ProteinPersistence
import SwiftUI

struct ParameterPresetsPage: View {
    let store: ProteinStore
    let apply: (ParameterPreset) -> Void
    @State private var items: [ParameterPreset] = []
    @State private var loaded = false
    @State private var issue: LocalizedStringResource?
    @State private var selected: UUID?
    @State private var pendingDeletion: ParameterPreset?
    @State private var deleting = false

    private var selection: ParameterPreset? { items.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(Text("presets.title")) {
                HStack(spacing: 8) {
                    Button("presets.delete", role: .destructive) { pendingDeletion = selection }
                        .disabled(selection == nil || deleting)
                    Button {
                        if let selection { apply(selection) }
                    } label: {
                        Label("presets.apply", systemImage: "arrow.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection == nil || deleting)
                }
                .controlSize(.large)
            }
            VStack(alignment: .leading, spacing: WorkspaceStyle.gap) {
                if let issue { WorkspaceIssue(message: issue).workspaceCard() }
                presetList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .workspaceCard(inset: 0)
            }
            .padding(.horizontal, WorkspaceStyle.pageInset)
            .padding(.bottom, WorkspaceStyle.pageInset)
        }
        .task { await load() }
        .confirmationDialog("presets.delete.title", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { item in
            Button("presets.delete", role: .destructive) { delete(item.id) }
            Button("common.cancel", role: .cancel) {}
        } message: { item in
            Text("presets.delete.message \(item.name)")
        }
    }

    @ViewBuilder
    private var presetList: some View {
        if !loaded {
            ProgressView("presets.loading")
        } else if items.isEmpty {
            ContentUnavailableView("presets.empty", systemImage: "bookmark", description: Text("presets.empty.hint"))
        } else {
            List(items, selection: $selected) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.name).font(WorkspaceStyle.sectionTitle).lineLimit(2).help(item.name)
                    HStack(spacing: 14) {
                        Label(item.parameters.species.workspaceTitle, systemImage: "circle.hexagongrid")
                        Label(item.parameters.startPolicy.workspaceTitle, systemImage: "a.circle")
                        Label(item.parameters.stopPolicy.workspaceTitle, systemImage: "stop.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    MotifValue(motifs: item.parameters.avoid.motifs)
                }
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .accessibilityElement(children: .combine)
                .tag(item.id)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func load() async {
        do {
            let result = try await runInBackground { try store.presets() }
            guard !Task.isCancelled else { return }
            items = result
            issue = nil
        } catch {
            guard !Task.isCancelled else { return }
            issue = storageMessage(for: error)
        }
        loaded = true
    }

    private func delete(_ id: UUID) {
        deleting = true
        WorkspaceWrites.run {
            defer { deleting = false }
            do {
                _ = try await runInBackground { try store.deletePreset(id: id) }
                selected = nil
                await load()
            } catch {
                issue = storageMessage(for: error)
            }
        }
    }
}

struct SaveParameterPreset: View {
    let store: ProteinStore
    let parameters: OptimizationParameters
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var issue: LocalizedStringResource?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let length = name.trimmingCharacters(in: .whitespacesAndNewlines).count
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceSectionTitle("presets.save", icon: "bookmark")
            VStack(alignment: .leading, spacing: 7) {
                Text("presets.name").font(.subheadline.weight(.semibold))
                TextField("presets.name", text: $name)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(Text("presets.name"))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .workspaceField(focused: nameFocused)
                    .focused($nameFocused)
                Text("presets.name.length \(length)").font(.caption).foregroundStyle(WorkspaceStyle.muted)
            }
            if let issue { WorkspaceIssue(message: issue) }
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("common.save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(1...80).contains(length) || saving)
            }
        }
        .padding(WorkspaceStyle.pageInset)
        .frame(width: 400)
        .background(WorkspaceStyle.surface)
        .interactiveDismissDisabled(saving)
        .task { nameFocused = true }
    }

    private func save() {
        let name = name
        saving = true
        WorkspaceWrites.run {
            defer { saving = false }
            do {
                _ = try await runInBackground { try store.createPreset(name: name, parameters: parameters) }
                dismiss()
            } catch {
                issue = storageMessage(for: error)
            }
        }
    }
}
