import ProteinDomain
import ProteinPersistence
import SwiftUI

struct RecordInspection: View {
    let record: SequenceRecord
    let parameters: OptimizationParameters
    let store: ProteinStore
    @State private var showsCodons = false
    @State private var rows: [CodonComparison]?
    @State private var codonIssue: LocalizedStringResource?
    @State private var isDNAVerified: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            WorkspaceRule()
            Text(record.name).font(WorkspaceStyle.sectionTitle).textSelection(.enabled).accessibilityAddTraits(.isHeader)
            Text(record.status.title).font(.callout).foregroundStyle(WorkspaceStyle.muted)
            if let error = record.error { Text(verbatim: error).textSelection(.enabled) }
            SequenceValue(title: "batch.protein.original", sequence: record.originalSequence.value)
            SequenceValue(title: "batch.protein.submitted", sequence: record.sequence.value)
            if let dna = record.dna {
                if record.status == .completed, isDNAVerified == true,
                   parameters.startPolicy.prependsATG(to: record.sequence) {
                    Label("history.start.added", systemImage: "a.circle")
                        .font(.callout)
                        .foregroundStyle(WorkspaceStyle.muted)
                }
                DisclosureGroup("history.dna") {
                    SequenceValue(title: "history.dna.sequence", sequence: dna)
                        .padding(.top, 5)
                }
                if record.status == .completed {
                    if let isDNAVerified {
                        Text(isDNAVerified ? "history.dna.verified" : "history.dna.verificationFailed")
                            .font(.callout)
                    }
                    if let checks = record.checks { checksView(checks) }
                }
                DisclosureGroup("history.codons", isExpanded: $showsCodons) {
                    if showsCodons { codonComparison(dna) }
                }
            }
            if !record.attempts.isEmpty {
                Text("history.attempts").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(record.attempts) { attempt in
                    AttemptInspection(attempt: attempt, recordID: record.id, store: store)
                }
            }
        }
        .task(id: record.id) {
            guard record.status == .completed else { return }
            do {
                _ = try await runInBackground {
                    try DNAValidation.reverifyCompleted(
                        record, avoiding: parameters.avoid, startPolicy: parameters.startPolicy
                    )
                }
                if !Task.isCancelled { isDNAVerified = true }
            } catch {
                if !Task.isCancelled { isDNAVerified = false }
            }
        }
    }

    private func checksView(_ checks: DNAChecks) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("history.dna.length \(checks.basePairCount)")
            Text("history.dna.gc \(checks.gcPercent.formatted(.number.precision(.fractionLength(1))))")
            Text("history.dna.motifs \(checks.checkedMotifCount)")
            Text(checks.hasTerminalStop ? "history.dna.hasStop" : "history.dna.noStop")
        }
        .foregroundStyle(.secondary)
        .font(.callout)
    }

    private func codonComparison(_ dna: String) -> some View {
        Group {
            if let rows {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        let translated = row.translated.map(String.init) ?? String(localized: "history.codons.invalid")
                        let matches = row.translated == row.expected
                        Label {
                            HStack {
                                Text(row.isPrependedStart
                                    ? "history.codons.start \(row.codon) \(translated)"
                                    : "history.codons.row \(row.position) \(String(row.expected)) \(row.codon) \(translated)")
                                    .font(WorkspaceStyle.sequenceFont)
                                if !matches {
                                    Text("history.codons.mismatch").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                        } icon: {
                            Image(systemName: matches ? "checkmark.circle" : "exclamationmark.circle")
                                .accessibilityHidden(true)
                        }
                        .accessibilityValue(Text(matches ? "history.codons.match" : "history.codons.mismatch"))
                    }
                }
            } else if let codonIssue {
                WorkspaceIssue(message: codonIssue)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(Text("history.codons.loading"))
            }
        }
        .padding(.top, 5)
        .task {
            guard rows == nil, codonIssue == nil else { return }
            do {
                let result = try await runInBackground { try DNAValidation.compareCodons(dna, with: record.sequence, startPolicy: parameters.startPolicy) }
                if !Task.isCancelled { rows = result }
            } catch {
                if !Task.isCancelled { codonIssue = "history.codons.length" }
            }
        }
    }
}

private struct AttemptInspection: View {
    let attempt: RequestAttempt
    let recordID: UUID
    let store: ProteinStore
    @State private var expanded = false
    @State private var showsResponse = false
    @State private var response: [String]?
    @State private var responseIssue: LocalizedStringResource?
    @State private var page = 0

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("history.attempt.effect \(String(localized: attempt.effect.title))")
                    if let status = attempt.httpStatus { Text("history.attempt.http \(status)") }
                    if let elapsed = attempt.elapsedMilliseconds { Text("history.attempt.elapsed \(elapsed)") }
                    if let error = attempt.error { Text(verbatim: error).textSelection(.enabled) }
                    DisclosureGroup("history.attempt.response", isExpanded: $showsResponse) {
                        if showsResponse { responseView }
                    }
                }
                .font(.callout)
                .padding(.top, 5)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("history.attempt.title \(attempt.number) \(String(localized: attempt.status.title))")
                Text(attempt.startedAt.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private var responseView: some View {
        Group {
            if let responseIssue {
                WorkspaceIssue(message: responseIssue)
            } else if let response, response.isEmpty {
                Text("history.attempt.noResponse").foregroundStyle(.secondary)
            } else if let response {
                if response.count > 1 {
                    HStack {
                        Button("history.response.previous") { page -= 1 }.disabled(page == 0)
                        Text("history.response.page \(page + 1) \(response.count)").monospacedDigit()
                        Button("history.response.next") { page += 1 }.disabled(page + 1 == response.count)
                    }
                }
                Text(verbatim: response[page]).font(WorkspaceStyle.sequenceFont).textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small).accessibilityLabel(Text("history.loading"))
            }
        }
        .padding(.top, 5)
        .task {
            guard response == nil else { return }
            responseIssue = nil
            do {
                let pages = try await runInBackground {
                    guard let bytes = try store.attemptResponse(id: attempt.id, recordID: recordID) else { return [String]() }
                    let text = String(data: bytes, encoding: .utf8) ?? bytes.base64EncodedString()
                    var pages: [String] = []
                    var index = text.startIndex
                    while index < text.endIndex {
                        let end = text.index(index, offsetBy: 8_192, limitedBy: text.endIndex) ?? text.endIndex
                        pages.append(String(text[index..<end]))
                        index = end
                    }
                    return pages
                }
                if !Task.isCancelled { response = pages }
            } catch {
                if !Task.isCancelled { responseIssue = storageMessage(for: error) }
            }
        }
    }
}
