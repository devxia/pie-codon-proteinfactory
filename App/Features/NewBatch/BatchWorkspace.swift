import AppKit
import ProteinApplication
import ProteinDomain
import ProteinPersistence
import SwiftUI
import UniformTypeIdentifiers

struct BatchWorkspace: View {
    @Binding var showsFilePicker: Bool
    @Binding var preset: ParameterPreset?
    let store: ProteinStore?
    let queue: QueueCoordinator?
    let didSave: (UUID) -> Void
    @State private var draft = BatchDraft()
    @State private var pendingSwitch: InputSwitch?
    @State private var fileRequest: FileRequest?
    @State private var fileFeedback: FileFeedback?
    @State private var validation: ValidationSnapshot?
    @State private var previewRequest: PreviewRequest?
    @State private var preview: ProteinImportPreview?
    @State private var prepareIssue: PrepareIssue?
    @FocusState private var focus: BatchField?

    var body: some View {
        let motifs = draft.motifs
        let parameters = OptimizationParameters(
            species: draft.species, startPolicy: draft.startPolicy, stopPolicy: draft.stopPolicy,
            avoid: (try? motifs.get()) ?? .empty
        )
        let input = draft.validationInput
        let key = input.map { ValidationKey(input: $0.identity, parameters: parameters) }
        let result = validation?.key == key ? validation?.result : nil
        let awaitingValidation = key != nil && result == nil
        let currentFileRequest = fileRequest
        let currentPreviewRequest = previewRequest

        Group {
            if let preview {
                BatchPreviewPage(preview: preview, store: store, queue: queue) {
                    self.preview = nil
                } didSave: { batchID in
                    self.preview = nil
                    draft = BatchDraft()
                    validation = nil
                    fileFeedback = nil
                    didSave(batchID)
                }
            } else {
                editor(motifs: motifs, result: result, awaitingValidation: awaitingValidation)
            }
        }
        .onChange(of: preset?.id) { _, _ in
            guard let selection = preset else { return }
            preview = nil
            previewRequest = nil
            draft.apply(selection.parameters)
            preset = nil
        }
        .onChange(of: key) { _, _ in prepareIssue = nil }
        .onChange(of: draft.name) { _, _ in prepareIssue = nil }
        .onChange(of: draft.customMotifs) { _, _ in prepareIssue = nil }
        .onChange(of: showsFilePicker) { _, open in
            guard open else { return }
            showsFilePicker = false
            if preview == nil && previewRequest == nil { chooseFile() }
        }
        .alert("batch.switch.title", isPresented: Binding(
            get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }
        ), presenting: pendingSwitch) { change in
            Button("batch.switch.discard", role: .destructive) { switchInput(to: change) }
            Button("common.cancel", role: .cancel) {}
        } message: { _ in
            Text("batch.switch.message")
        }
        .task(id: currentFileRequest?.id) {
            guard let currentFileRequest else { return }
            await loadFile(currentFileRequest)
        }
        .task(id: key) {
            guard let input, let key else {
                if draft.validationInput == nil { validation = nil }
                return
            }
            await validate(input, key: key)
        }
        .task(id: currentPreviewRequest?.id) {
            guard let currentPreviewRequest else { return }
            await prepare(currentPreviewRequest)
        }
    }

    private func editor(
        motifs: Result<AvoidMotifs, any Error>, result: Result<ProteinImportValidation, any Error>?, awaitingValidation: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceHeader(Text("batch.title"), subtitle: Text("batch.subtitle"))

            GeometryReader { dimensions in
                HStack(alignment: .top, spacing: WorkspaceStyle.gap) {
                    inputPane(result: result, awaitingValidation: awaitingValidation)
                    ParameterInspector(
                        species: $draft.species, startPolicy: $draft.startPolicy, stopPolicy: $draft.stopPolicy,
                        enzymes: $draft.enzymes, customMotifs: $draft.customMotifs, motifs: motifs, focus: $focus, store: store
                    )
                    .frame(width: min(350, max(290, dimensions.size.width * 0.336)))
                }
                .padding(.horizontal, WorkspaceStyle.pageInset)
            }
            .disabled(previewRequest != nil)

            WorkspaceActionBar {
                VStack(alignment: .leading, spacing: 4) {
                    if let prepareIssue {
                        WorkspaceIssue(message: prepareIssue.message)
                    }
                    Label("batch.localOnly", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 10)
                if previewRequest != nil {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("batch.preparing"))
                }
                Button {
                    requestPreview(motifs: motifs, result: result)
                } label: {
                    HStack(spacing: 8) {
                        Text("batch.prepare")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(awaitingValidation || fileRequest != nil || previewRequest != nil)
            }
        }
    }

    private func inputPane(result: Result<ProteinImportValidation, any Error>?, awaitingValidation: Bool) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: WorkspaceStyle.gap) {
                    VStack(alignment: .leading, spacing: 16) {
                        WorkspaceSectionTitle("batch.input.section", icon: "text.alignleft")

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Text("batch.name").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                Text("batch.name.prompt").font(.caption).foregroundStyle(WorkspaceStyle.muted)
                                    .accessibilityHidden(true)
                            }
                            TextField("batch.name", text: $draft.name, prompt: Text(verbatim: ""))
                                .textFieldStyle(.plain)
                                .accessibilityLabel(Text("batch.name"))
                                .accessibilityHint(Text("batch.name.prompt"))
                                .padding(.horizontal, 10)
                                .frame(minHeight: 34)
                                .workspaceField(focused: focus == .name)
                                .focused($focus, equals: .name)
                        }
                        .id(BatchField.name)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("batch.input").font(.subheadline.weight(.semibold))
                            Picker("batch.input", selection: Binding(
                                get: { draft.mode }, set: { requestSwitch(to: .init(mode: $0)) }
                            )) {
                                ForEach(BatchInputMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.large)
                            .labelsHidden()
                        }

                        Group {
                            if draft.mode == .paste {
                                pastePane
                            } else {
                                BatchFilePane(
                                    draft: $draft, request: fileRequest, feedback: fileFeedback, focus: $focus,
                                    chooseFile: chooseFile, cancel: cancelFileLoad,
                                    dropFile: { receiveFile($0, mode: draft.mode) }
                                )
                            }
                        }
                        .id(BatchField.input)
                    }
                    .workspaceCard()

                    validationPane(result: result, awaitingValidation: awaitingValidation)
                        .id(BatchField.checks)
                }
                .padding(.bottom, WorkspaceStyle.gap)
            }
            .task(id: prepareIssue?.id) {
                guard let field = prepareIssue?.field, field != .motifs else { return }
                scroll.scrollTo(field, anchor: .center)
                await Task.yield()
                if !Task.isCancelled { focus = field }
            }
        }
    }

    private var pastePane: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                if draft.pastedText.isEmpty {
                    Text(verbatim: ">sample_01\nACDEFGHIK")
                        .font(WorkspaceStyle.sequenceFont)
                        .foregroundStyle(WorkspaceStyle.muted)
                        .padding(.leading, 13)
                        .padding(.top, 11)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $draft.pastedText)
                    .font(WorkspaceStyle.sequenceFont)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(draft.pastedText.isEmpty ? .hidden : .automatic)
                    .padding(8)
                    .focused($focus, equals: .input)
                    .accessibilityLabel(Text("batch.paste.editor"))
            }
            .frame(height: 205)
            .workspaceField(focused: focus == .input)

            Text("batch.paste.hint").font(.callout).foregroundStyle(WorkspaceStyle.muted)
        }
    }

    @ViewBuilder
    private func validationPane(result: Result<ProteinImportValidation, any Error>?, awaitingValidation: Bool) -> some View {
        if awaitingValidation {
            ProgressView("batch.validating").controlSize(.small).workspaceCard()
        } else if let result {
            switch result {
            case .success(let report):
                RecordValidationView(report: report, focus: $focus).workspaceCard()
            case .failure(let error):
                WorkspaceIssue(message: workspaceMessage(for: error))
                    .workspaceCard()
                    .focusable()
                    .focused($focus, equals: .checks)
            }
        }
    }

    private func chooseFile() {
        let mode = draft.mode
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = switch mode {
        case .fasta: String(localized: "batch.fasta.supported")
        case .spreadsheet: String(localized: "spreadsheet.supported")
        case .paste: String(localized: "batch.file.supported")
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                fileFeedback = .canceled
                return
            }
            receiveFile(url, mode: mode)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func receiveFile(_ url: URL, mode: BatchInputMode) {
        guard url.isFileURL else { return }
        let resolvedMode = mode.isFile ? mode : FASTAInspection.extensions.contains(url.pathExtension.lowercased()) ? .fasta : .spreadsheet
        requestSwitch(to: .init(mode: resolvedMode, url: url))
    }

    private func requestSwitch(to change: InputSwitch) {
        if change.mode == draft.mode {
            if let url = change.url { beginFileLoad(url) }
        } else if draft.hasContent {
            pendingSwitch = change
        } else {
            switchInput(to: change)
        }
    }

    private func switchInput(to change: InputSwitch) {
        pendingSwitch = nil
        fileRequest = nil
        fileFeedback = nil
        prepareIssue = nil
        validation = nil
        draft.pastedText = ""
        draft.setFile(nil)
        draft.mode = change.mode
        if let url = change.url { beginFileLoad(url) }
    }

    private func beginFileLoad(_ url: URL) {
        fileFeedback = nil
        prepareIssue = nil
        fileRequest = FileRequest(url: url, mode: draft.mode)
    }

    private func cancelFileLoad() {
        fileRequest = nil
        fileFeedback = .canceled
    }

    private func loadFile(_ request: FileRequest) async {
        do {
            let file = try await runInBackground { try BatchFile.read(url: request.url, mode: request.mode) }
            guard !Task.isCancelled, fileRequest?.id == request.id else { return }
            draft.setFile(file)
        } catch {
            guard !Task.isCancelled, fileRequest?.id == request.id else { return }
            fileFeedback = .failed(workspaceMessage(for: error))
        }
        fileRequest = nil
    }

    private func validate(_ input: ValidationInput, key: ValidationKey) async {
        do {
            if case .paste = input { try await Task.sleep(for: .milliseconds(160)) }
            let report = try await runInBackground { try input.validate(parameters: key.parameters) }
            guard !Task.isCancelled else { return }
            validation = ValidationSnapshot(key: key, result: .success(report))
        } catch {
            guard !Task.isCancelled else { return }
            validation = ValidationSnapshot(key: key, result: .failure(error))
        }
    }

    private func requestPreview(motifs: Result<AvoidMotifs, any Error>, result: Result<ProteinImportValidation, any Error>?) {
        guard let result else {
            if draft.mode == .spreadsheet, let sheet = draft.sheet {
                let message: LocalizedStringResource = if sheet.rows.isEmpty { "spreadsheet.sheetEmpty" }
                    else if sheet.columnCount < 2 { "batch.mapping.insufficient" }
                    else if draft.firstRowIsHeader && sheet.rows.count == 1 { "batch.error.noDataRows" }
                    else { "batch.mapping.required" }
                showError(message, at: .mapping)
            } else {
                showError(draft.mode == .paste ? "batch.error.pasteRequired" : "batch.error.fileRequired", at: .input)
            }
            return
        }
        switch result {
        case .failure(let error):
            let field: BatchField = error is SpreadsheetMappingError ? .mapping : draft.mode == .paste ? .input : .checks
            showError(workspaceMessage(for: error), at: field)
        case .success(let report):
            if let first = report.records.first(where: { !$0.issues.isEmpty }) {
                showError("batch.error.fixRecords", at: .record(first.position))
            } else if let issue = report.batchIssues.first {
                showError(workspaceMessage(for: issue), at: .checks)
            } else if case .failure(let error) = motifs {
                showError(workspaceMessage(for: error), at: .motifs)
            } else {
                prepareIssue = nil
                previewRequest = PreviewRequest(name: draft.name, validation: report)
            }
        }
    }

    private func prepare(_ request: PreviewRequest) async {
        do {
            let prepared = try await runInBackground { try ProteinImport.prepare(name: request.name, validation: request.validation) }
            guard !Task.isCancelled, previewRequest?.id == request.id else { return }
            previewRequest = nil
            preview = prepared
        } catch {
            guard !Task.isCancelled, previewRequest?.id == request.id else { return }
            previewRequest = nil
            showError(workspaceMessage(for: error), at: (error as? BatchInputError) == .invalidBatchName ? .name : .checks)
        }
    }

    private func showError(_ message: LocalizedStringResource, at field: BatchField) {
        prepareIssue = PrepareIssue(message: message, field: field)
        if field == .motifs { focus = field }
    }

    private struct PrepareIssue {
        let id = UUID()
        let message: LocalizedStringResource
        let field: BatchField
    }

    private struct InputSwitch {
        let mode: BatchInputMode
        var url: URL? = nil
    }

    private struct ValidationKey: Equatable, Sendable {
        let input: ValidationInput.Identity
        let parameters: OptimizationParameters
    }

    private struct ValidationSnapshot {
        let key: ValidationKey
        let result: Result<ProteinImportValidation, any Error>
    }

    private struct PreviewRequest: Sendable {
        let id = UUID()
        let name: String
        let validation: ProteinImportValidation
    }
}

enum BatchField: Hashable {
    case name, input, mapping, motifs, checks, record(Int)
}

struct FileRequest: Sendable {
    let id = UUID()
    let url: URL
    let mode: BatchInputMode
}

enum FileFeedback {
    case canceled
    case failed(LocalizedStringResource)
}
