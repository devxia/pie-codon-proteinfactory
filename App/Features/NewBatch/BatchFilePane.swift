import SequenceIO
import SwiftUI

struct BatchFilePane: View {
    @Binding var draft: BatchDraft
    let request: FileRequest?
    let feedback: FileFeedback?
    let focus: FocusState<BatchField?>.Binding
    let chooseFile: () -> Void
    let cancel: () -> Void
    let dropFile: (URL) -> Void
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: draft.mode == .fasta ? "doc.text" : "tablecells")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(WorkspaceStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(WorkspaceStyle.accentBackground, in: .rect(cornerRadius: WorkspaceStyle.fieldRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    switch draft.file {
                    case .fasta(let file):
                        Text(file.filename).font(.headline).textSelection(.enabled)
                        let size = file.byteCount.formatted(.byteCount(style: .binary))
                        Text("batch.fasta.fileSize \(size)").foregroundStyle(.secondary)
                    case .spreadsheet(let file):
                        Text(file.filename).font(.headline).textSelection(.enabled)
                        let format = file.format.rawValue.uppercased()
                        let size = file.byteCount.formatted(.byteCount(style: .binary))
                        Text("\(format) · \(size)").foregroundStyle(.secondary)
                    case nil:
                        Text(draft.mode == .fasta ? "batch.fasta.supported" : "spreadsheet.supported")
                            .foregroundStyle(.secondary)
                    }
                    Text("batch.file.drop").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: chooseFile) {
                    Label(draft.mode == .fasta ? "batch.fasta.choose" : "spreadsheet.choose", systemImage: "folder")
                }
                .focused(focus, equals: .input)
            }
            .padding(14)
            .frame(minHeight: 98)
            .background(isDropTarget ? WorkspaceStyle.accentBackground : WorkspaceStyle.inset,
                        in: .rect(cornerRadius: WorkspaceStyle.fieldRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius)
                    .strokeBorder(isDropTarget ? WorkspaceStyle.accent : WorkspaceStyle.border,
                                  style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .allowsHitTesting(false)
            }
            .dropDestination(for: URL.self) { files, _ in
                guard files.count == 1, let file = files.first, file.isFileURL else { return false }
                dropFile(file)
                return true
            } isTargeted: { isDropTarget = $0 }

            if let request {
                HStack(spacing: 12) {
                    ProgressView("batch.file.loading \(request.url.lastPathComponent)").controlSize(.small)
                    Button("common.cancel", action: cancel)
                }
            } else if let feedback {
                switch feedback {
                case .canceled:
                    Label("batch.file.canceled", systemImage: "info.circle").foregroundStyle(.secondary)
                case .failed(let message):
                    WorkspaceIssue(message: message)
                }
            }

            if case .spreadsheet(let file) = draft.file, let sheet = draft.sheet {
                SpreadsheetPreview(
                    file: file,
                    selectedSheet: Binding(get: { draft.worksheetIndex }, set: { draft.setWorksheet($0) }),
                    firstRowIsHeader: $draft.firstRowIsHeader
                )
                .id(file.id)

                mappingPane(sheet)
                    .id(BatchField.mapping)
            }
        }
    }

    @ViewBuilder
    private func mappingPane(_ sheet: SpreadsheetSheet) -> some View {
        if sheet.rows.isEmpty || sheet.columnCount < 2 || (draft.firstRowIsHeader && sheet.rows.count == 1) {
            WorkspaceIssue(message: sheet.rows.isEmpty ? "spreadsheet.sheetEmpty"
                : sheet.columnCount < 2 ? "batch.mapping.insufficient" : "batch.error.noDataRows")
                .focusable()
                .focused(focus, equals: .mapping)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("batch.mapping").font(.headline).accessibilityAddTraits(.isHeader)
                columnPicker("batch.mapping.name", selection: $draft.nameColumn, sheet: sheet)
                    .focused(focus, equals: .mapping)
                columnPicker("batch.mapping.sequence", selection: $draft.sequenceColumn, sheet: sheet)
                if draft.nameColumn == nil || draft.sequenceColumn == nil {
                    Text("batch.mapping.required").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func columnPicker(_ title: LocalizedStringKey, selection: Binding<Int?>, sheet: SpreadsheetSheet) -> some View {
        let header = draft.firstRowIsHeader ? sheet.rows.first ?? [] : []
        return Picker(title, selection: selection) {
            Text("batch.mapping.choose").tag(nil as Int?)
            ForEach(0..<sheet.columnCount, id: \.self) { index in
                Text(SpreadsheetPreview.columnTitle(index, header: header)).tag(index as Int?)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
