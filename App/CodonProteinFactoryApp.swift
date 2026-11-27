import SwiftUI

@main
struct CodonProteinFactoryApp: App {
    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? "Codon ProteinFactory"

    @NSApplicationDelegateAdaptor(WorkspaceLifecycle.self) private var lifecycle
    @State private var showsFilePicker = false
    @AppStorage("workspace.appearance") private var appearance: WorkspaceAppearance = .system

    init() {
        #if DEBUG
        AppSmokeTest.startDeadline()
        #endif
    }

    var body: some Scene {
        Window(Self.displayName, id: "main") {
            WorkspaceRoot(showsFilePicker: $showsFilePicker)
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 1080, minHeight: 720)
                #if DEBUG
                .background {
                    if AppSmokeTest.isRequested {
                        AppSmokeTest.WindowProbe()
                    }
                }
                #endif
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("batch.file.open") { showsFilePicker = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
