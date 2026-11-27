import AppKit
import SwiftUI

struct WorkspaceSettingsPage: View {
    let directory: URL
    @AppStorage("workspace.appearance") private var appearance: WorkspaceAppearance = .system
    @AppStorage("workspace.language") private var language: WorkspaceLanguage = .system

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(Text("settings.title"))
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceStyle.gap) {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkspaceSectionTitle("settings.display", icon: "macwindow")
                        Picker("settings.appearance", selection: $appearance) {
                            ForEach(WorkspaceAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        WorkspaceRule()
                        Picker("settings.language", selection: $language) {
                            ForEach(WorkspaceLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text("settings.language.restart").font(.callout).foregroundStyle(WorkspaceStyle.muted)
                    }
                    .workspaceCard()

                    VStack(alignment: .leading, spacing: 12) {
                        WorkspaceSectionTitle("settings.storage", icon: "internaldrive")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("settings.location").font(.subheadline.weight(.semibold))
                            Text(verbatim: directory.path)
                                .font(WorkspaceStyle.sequenceFont)
                                .foregroundStyle(WorkspaceStyle.muted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .workspaceField()
                        }
                        Button {
                            NSWorkspace.shared.open(directory)
                        } label: {
                            Label("settings.finder", systemImage: "folder")
                        }
                    }
                    .workspaceCard()
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, WorkspaceStyle.pageInset)
                .padding(.bottom, WorkspaceStyle.pageInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: language) { _, value in value.save() }
    }
}

enum WorkspaceAppearance: String, CaseIterable {
    case system, light, dark

    var title: LocalizedStringResource {
        switch self {
        case .system: "settings.system"
        case .light: "settings.light"
        case .dark: "settings.dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum WorkspaceLanguage: String, CaseIterable {
    case system, chinese, english

    var title: LocalizedStringResource {
        switch self {
        case .system: "settings.system"
        case .chinese: "settings.chinese"
        case .english: "settings.english"
        }
    }

    func save() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .chinese: UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }
}
