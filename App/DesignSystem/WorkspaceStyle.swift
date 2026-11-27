import AppKit
import SwiftUI

@MainActor
enum WorkspaceStyle {
    static let pageInset: CGFloat = 28
    static let cardInset: CGFloat = 18
    static let gap: CGFloat = 16
    static let cornerRadius: CGFloat = 14
    static let fieldRadius: CGFloat = 8
    static let sequenceFont = Font.system(size: 13, design: .monospaced)
    static let pageTitle = Font.system(size: 32, weight: .semibold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)

    static let pageBackground = adaptive(light: 0xF4F5F0, dark: 0x171D1A)
    static let sidebar = adaptive(light: 0xE9EDE6, dark: 0x1C2521)
    static let surface = adaptive(light: 0xFFFefa, dark: 0x222B26)
    static let inset = adaptive(light: 0xF3F5EF, dark: 0x1B231F)
    static let border = adaptive(light: 0xD8E1D8, dark: 0x3C4941)
    static let text = adaptive(light: 0x182B23, dark: 0xE9F1EB)
    static let muted = adaptive(light: 0x52645A, dark: 0xAABCB1)
    static let accent = adaptive(light: 0x126356, dark: 0x83D3BE)
    static let accentBackground = adaptive(light: 0xE0F0E8, dark: 0x2D463B)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double(hex >> 16) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct WorkspaceHeader<Actions: View>: View {
    let title: Text
    let subtitle: Text?
    @ViewBuilder let actions: Actions

    init(_ title: Text, subtitle: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                title.font(WorkspaceStyle.pageTitle).tracking(-0.7)
                    .foregroundStyle(WorkspaceStyle.text)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    subtitle.font(.callout).foregroundStyle(WorkspaceStyle.muted).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, WorkspaceStyle.pageInset)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }
}

extension WorkspaceHeader where Actions == EmptyView {
    init(_ title: Text, subtitle: Text? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct WorkspaceSectionTitle: View {
    let title: LocalizedStringKey
    let icon: String

    init(_ title: LocalizedStringKey, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title).font(WorkspaceStyle.sectionTitle).foregroundStyle(WorkspaceStyle.text)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WorkspaceStyle.accent)
                .frame(width: 28, height: 28)
                .background(WorkspaceStyle.accentBackground, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct WorkspaceRule: View {
    var body: some View {
        Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct WorkspaceSearchField: View {
    let title: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WorkspaceStyle.muted)
                .accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(title).foregroundStyle(WorkspaceStyle.muted))
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(title))
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .workspaceField()
    }
}

extension View {
    func workspaceCard(inset: CGFloat = WorkspaceStyle.cardInset) -> some View {
        padding(inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface, in: .rect(cornerRadius: WorkspaceStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.cornerRadius)
                    .strokeBorder(WorkspaceStyle.border)
                    .allowsHitTesting(false)
            }
    }

    func workspaceField(focused: Bool = false) -> some View {
        background(WorkspaceStyle.inset, in: .rect(cornerRadius: WorkspaceStyle.fieldRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius)
                    .strokeBorder(focused ? WorkspaceStyle.accent : WorkspaceStyle.border, lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

struct WorkspaceActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceRule()
            HStack(spacing: 14) { content }
                .padding(.horizontal, WorkspaceStyle.pageInset)
                .padding(.vertical, 13)
        }
        .background(WorkspaceStyle.surface)
    }
}
