import Foundation
import ProteinApplication
import ProteinDomain
import SequenceIO

struct BatchDraft {
    var name = ""
    var mode: BatchInputMode = .paste
    var pastedText = ""
    var file: BatchFile?
    var worksheetIndex = 0
    var firstRowIsHeader = false
    var nameColumn: Int?
    var sequenceColumn: Int?
    var species: Species = .defaultD2P
    var startPolicy: StartCodonPolicy = .none
    var stopPolicy: StopPolicy = .add
    var enzymes: Set<RestrictionEnzyme> = []
    var customMotifs = ""

    var hasContent: Bool { !pastedText.isEmpty || file != nil }

    var motifs: Result<AvoidMotifs, any Error> {
        Result { try AvoidMotifs(customMotifs, enzymes: RestrictionEnzyme.allCases.filter(enzymes.contains)) }
    }

    var sheet: SpreadsheetSheet? {
        guard case let .spreadsheet(inspection) = file,
              inspection.spreadsheet.sheets.indices.contains(worksheetIndex) else { return nil }
        return inspection.spreadsheet.sheets[worksheetIndex]
    }

    var validationInput: ValidationInput? {
        switch mode {
        case .paste:
            return pastedText.isEmpty ? nil : .paste(pastedText)
        case .fasta:
            guard case let .fasta(inspection) = file else { return nil }
            return .fasta(inspection)
        case .spreadsheet:
            guard case let .spreadsheet(inspection) = file, let nameColumn, let sequenceColumn else { return nil }
            return .spreadsheet(inspection, .init(
                worksheetIndex: worksheetIndex, firstRowIsHeader: firstRowIsHeader,
                nameColumn: nameColumn, sequenceColumn: sequenceColumn
            ))
        }
    }

    mutating func apply(_ parameters: OptimizationParameters) {
        species = parameters.species
        startPolicy = parameters.startPolicy
        stopPolicy = parameters.stopPolicy
        enzymes = []
        customMotifs = parameters.avoid.motifs.joined(separator: ", ")
    }

    mutating func setWorksheet(_ index: Int) {
        worksheetIndex = index
        firstRowIsHeader = false
        nameColumn = nil
        sequenceColumn = nil
    }

    mutating func setFile(_ file: BatchFile?) {
        self.file = file
        setWorksheet(0)
    }
}

enum BatchInputMode: String, CaseIterable, Sendable {
    case paste, fasta, spreadsheet

    var isFile: Bool { self != .paste }
}

enum BatchFile: Sendable {
    case fasta(FASTAInspection)
    case spreadsheet(SpreadsheetInspection)

    static func read(url: URL, mode: BatchInputMode) throws -> Self {
        switch mode {
        case .fasta: .fasta(try FASTAInspection(url: url))
        case .spreadsheet: .spreadsheet(try SpreadsheetInspection(url: url))
        case .paste: throw CocoaError(.fileReadUnknown)
        }
    }
}

enum ValidationInput: Sendable {
    case paste(String)
    case fasta(FASTAInspection)
    case spreadsheet(SpreadsheetInspection, SpreadsheetColumnMapping)

    enum Identity: Equatable, Sendable {
        case paste(String)
        case fasta(UUID)
        case spreadsheet(UUID, SpreadsheetColumnMapping)
    }

    var identity: Identity {
        switch self {
        case .paste(let text): .paste(text)
        case .fasta(let inspection): .fasta(inspection.id)
        case .spreadsheet(let inspection, let mapping): .spreadsheet(inspection.id, mapping)
        }
    }

    func validate(parameters: OptimizationParameters) throws -> ProteinImportValidation {
        let records = switch self {
        case .paste(let text): try ProteinImport.read(pastedText: text)
        case .fasta(let inspection): inspection.records
        case .spreadsheet(let inspection, let mapping): try ProteinImport.read(spreadsheet: inspection.spreadsheet, mapping: mapping)
        }
        return try ProteinImport.validate(records, parameters: parameters)
    }
}

func runInBackground<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
    let worker = Task.detached(priority: .userInitiated, operation: work)
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}
