import ProteinDomain
import ProteinPersistence
import SwiftUI

struct ParameterInspector: View {
    @Binding var species: Species
    @Binding var startPolicy: StartCodonPolicy
    @Binding var stopPolicy: StopPolicy
    @Binding var enzymes: Set<RestrictionEnzyme>
    @Binding var customMotifs: String
    let motifs: Result<AvoidMotifs, any Error>
    let focus: FocusState<BatchField?>.Binding
    let store: ProteinStore?
    @State private var showsSave = false

    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceSectionTitle("batch.parameters", icon: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 12) {
                    Picker("batch.species", selection: $species) {
                        ForEach(Species.allCases, id: \.self) { Text($0.workspaceTitle).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("batch.start", selection: $startPolicy) {
                            ForEach(StartCodonPolicy.allCases, id: \.self) { Text($0.workspaceTitle).tag($0) }
                        }
                        Text(startPolicy.workspaceHint)
                            .font(.caption)
                            .foregroundStyle(WorkspaceStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("batch.stop", selection: $stopPolicy) {
                            ForEach(StopPolicy.allCases, id: \.self) { Text($0.workspaceTitle).tag($0) }
                        }
                        let hint: LocalizedStringResource = stopPolicy == .add ? "batch.stop.add.hint" : "batch.stop.preserve.hint"
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(WorkspaceStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                WorkspaceRule()

                VStack(alignment: .leading, spacing: 10) {
                    Text("batch.enzymes").font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(RestrictionEnzyme.allCases, id: \.self) { enzyme in
                            Toggle(isOn: selection(of: enzyme)) {
                                Text(enzyme.rawValue)
                            }
                            .toggleStyle(.checkbox)
                            .help(enzyme.motif)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("batch.motifs.custom").font(.subheadline.weight(.semibold))
                    TextField("batch.motifs.custom", text: $customMotifs, prompt: Text(verbatim: "GAATTC, GGT(A/T)ACC"), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(WorkspaceStyle.sequenceFont)
                        .lineLimit(2...4)
                        .padding(9)
                        .workspaceField(focused: focus.wrappedValue == .motifs)
                        .focused(focus, equals: .motifs)
                    Text("batch.motifs.hint").font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("batch.motifs.final").font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    switch motifs {
                    case .success(let list):
                        MotifValue(motifs: list.motifs)
                        Button {
                            showsSave = true
                        } label: {
                            Label("presets.save", systemImage: "bookmark")
                        }
                        .controlSize(.regular)
                        .disabled(store == nil)
                    case .failure(let error):
                        WorkspaceIssue(message: workspaceMessage(for: error))
                    }
                }
            }
            .workspaceCard()
            .padding(.bottom, WorkspaceStyle.gap)
        }
        .accessibilityLabel(Text("batch.parameters"))
        .sheet(isPresented: $showsSave) {
            if let store, let list = try? motifs.get() {
                SaveParameterPreset(store: store, parameters: .init(species: species, startPolicy: startPolicy,
                                                                    stopPolicy: stopPolicy, avoid: list))
            }
        }
    }

    private func selection(of enzyme: RestrictionEnzyme) -> Binding<Bool> {
        Binding {
            enzymes.contains(enzyme)
        } set: { selected in
            if selected { enzymes.insert(enzyme) } else { enzymes.remove(enzyme) }
        }
    }
}

struct MotifValue: View {
    let motifs: [String]

    var body: some View {
        if motifs.isEmpty {
            Text("batch.motifs.none").foregroundStyle(.secondary)
        } else {
            Text(motifs.joined(separator: ", "))
                .font(WorkspaceStyle.sequenceFont)
                .textSelection(.enabled)
        }
    }
}
