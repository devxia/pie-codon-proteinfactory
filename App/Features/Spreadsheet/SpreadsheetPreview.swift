import AppKit
import SequenceIO
import SwiftUI

struct SpreadsheetPreview: View {
    let file: SpreadsheetInspection
    @Binding var selectedSheet: Int
    @Binding var firstRowIsHeader: Bool

    private var sheet: SpreadsheetSheet { file.spreadsheet.sheets[selectedSheet] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if file.format == .xlsx {
                Picker("spreadsheet.sheet", selection: $selectedSheet) {
                    ForEach(file.spreadsheet.sheets.indices, id: \.self) { index in
                        Text(file.spreadsheet.sheets[index].name ?? "").tag(index)
                    }
                }
            }
            HStack(spacing: 10) {
                Toggle("spreadsheet.header", isOn: $firstRowIsHeader)
                    .disabled(sheet.rows.isEmpty)
                Spacer()
                let rows = max(0, sheet.rows.count - (firstRowIsHeader ? 1 : 0))
                Text("spreadsheet.dimensions \(rows) \(sheet.columnCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if sheet.containsFormulas {
                Label("spreadsheet.formulaNotice", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if sheet.rows.isEmpty {
                Text("spreadsheet.sheetEmpty").foregroundStyle(.secondary)
            } else {
                SpreadsheetTable(sheet: sheet, firstRowIsHeader: firstRowIsHeader)
                    .id(selectedSheet)
                    .frame(height: 190)
                    .overlay {
                        RoundedRectangle(cornerRadius: WorkspaceStyle.fieldRadius)
                            .strokeBorder(WorkspaceStyle.border)
                            .allowsHitTesting(false)
                    }
                    .clipShape(.rect(cornerRadius: WorkspaceStyle.fieldRadius))
            }
        }
    }

    static func columnTitle(_ index: Int, header: [String] = []) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var number = index + 1
        var letter = ""
        while number > 0 {
            number -= 1
            letter.insert(letters[number % letters.count], at: letter.startIndex)
            number /= letters.count
        }
        let label = header.indices.contains(index) ? header[index] : ""
        let title = label.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? ""
        return title.isEmpty ? letter : "\(letter) · \(title)"
    }
}

private struct SpreadsheetTable: NSViewRepresentable {
    let sheet: SpreadsheetSheet
    let firstRowIsHeader: Bool

    func makeCoordinator() -> Coordinator { Coordinator(sheet: sheet) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.setAccessibilityLabel(String(localized: "spreadsheet.preview"))
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.rowHeight = 25
        table.style = .fullWidth
        context.coordinator.configureColumns(in: table)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.setHeader(firstRowIsHeader, in: table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let sheet: SpreadsheetSheet
        private let blankCellLabel = String(localized: "spreadsheet.blankCell")
        private var firstRowIsHeader = false

        init(sheet: SpreadsheetSheet) { self.sheet = sheet }

        func configureColumns(in table: NSTableView) {
            let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rowNumber"))
            rowNumber.title = String(localized: "spreadsheet.row")
            rowNumber.width = 58
            rowNumber.minWidth = 45
            table.addTableColumn(rowNumber)
            for index in 0..<sheet.columnCount {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = SpreadsheetPreview.columnTitle(index)
                column.width = 156
                column.minWidth = 70
                table.addTableColumn(column)
            }
        }

        func setHeader(_ enabled: Bool, in table: NSTableView) {
            guard enabled != firstRowIsHeader else { return }
            firstRowIsHeader = enabled
            let header = enabled ? sheet.rows.first ?? [] : []
            for (index, column) in table.tableColumns.dropFirst().enumerated() {
                let label = header.indices.contains(index) ? header[index] : ""
                column.title = SpreadsheetPreview.columnTitle(index, header: header)
                column.headerToolTip = label.isEmpty ? nil : label
            }
            table.headerView?.needsDisplay = true
            table.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            max(0, sheet.rows.count - (firstRowIsHeader ? 1 : 0))
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let rowIndex = row + (firstRowIsHeader ? 1 : 0)
            guard let tableColumn, sheet.rows.indices.contains(rowIndex) else { return nil }
            let column = Int(tableColumn.identifier.rawValue)
            let isRowNumber = column == nil
            let cells = sheet.rows[rowIndex]
            let sourceRow = sheet.sourceRows[rowIndex]
            let value = if let column { cells.indices.contains(column) ? cells[column] : "" } else { String(sourceRow) }
            let reuseID = NSUserInterfaceItemIdentifier(isRowNumber ? "rowLabel" : "cellLabel")
            let label: NSTextField
            if let reused = tableView.makeView(withIdentifier: reuseID, owner: nil) as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = reuseID
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                if isRowNumber {
                    label.textColor = .secondaryLabelColor
                    label.alignment = .right
                    label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                }
            }
            label.stringValue = value
            label.setAccessibilityLabel(isRowNumber ? String(localized: "batch.source.row \(sourceRow)") : value.isEmpty ? blankCellLabel : value)
            label.toolTip = isRowNumber || value.isEmpty ? nil : value
            return label
        }
    }
}
