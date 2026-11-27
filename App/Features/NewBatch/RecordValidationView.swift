import ProteinApplication
import SwiftUI

struct RecordValidationView: View {
    let report: ProteinImportValidation
    let focus: FocusState<BatchField?>.Binding

    var body: some View {
        let invalidCount = report.records.count { !$0.issues.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            WorkspaceSectionTitle("batch.checks", icon: "checkmark.circle")
            Text("batch.checks.summary \(report.records.count - invalidCount) \(invalidCount)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !report.batchIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(report.batchIssues.indices, id: \.self) { index in
                        WorkspaceIssue(message: workspaceMessage(for: report.batchIssues[index]))
                    }
                }
                .focusable()
                .focused(focus, equals: .checks)
            }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(report.records, id: \.position) { record in
                    recordRow(record)
                        .id(BatchField.record(record.position))
                }
            }
        }
    }

    private func recordRow(_ record: ProteinImportRecordValidation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceRule()
            DisclosureGroup {
                if let sequence = record.originalSequence {
                    SequenceValue(title: "batch.protein.normalized", sequence: sequence.value)
                } else if let sequence = record.record.rawSequence, !sequence.isEmpty {
                    SequenceValue(title: "batch.protein.input", sequence: sequence)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        if let name = record.name ?? record.record.rawName, !name.isEmpty {
                            Text(name).lineLimit(1).help(name)
                        } else {
                            Text("batch.record.unnamed").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.record.source.workspaceTitle)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let sequence = record.originalSequence {
                        Text(sequence.value).font(WorkspaceStyle.sequenceFont)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            if record.issues.isEmpty {
                Label("batch.record.valid", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(WorkspaceStyle.accent)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.issues.indices, id: \.self) { index in
                        WorkspaceIssue(message: record.issues[index].workspaceMessage)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(record.record.source.workspaceTitle) + Text(verbatim: ": ") + Text(record.issues.map { String(localized: $0.workspaceMessage) }.joined(separator: " ")))
                .focusable()
                .focused(focus, equals: .record(record.position))
            }
        }
        .padding(.bottom, 8)
    }
}

struct WorkspaceIssue: View {
    let message: LocalizedStringResource

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
        .font(.callout)
    }
}

struct SequenceValue: View {
    let title: LocalizedStringResource
    let sequence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: sequence)
                .font(WorkspaceStyle.sequenceFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .workspaceField()
        }
    }
}
