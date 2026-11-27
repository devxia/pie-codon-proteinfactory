import Foundation
import ProteinApplication
import ProteinDomain
import SequenceIO

extension BatchInputMode {
    var title: LocalizedStringResource {
        switch self {
        case .paste: "batch.input.paste"
        case .fasta: "batch.input.fasta"
        case .spreadsheet: "batch.input.spreadsheet"
        }
    }
}

extension Species {
    var workspaceTitle: LocalizedStringResource {
        switch self {
        case .defaultD2P: "batch.species.default"
        case .escherichiaColi: "batch.species.ecoli"
        case .chineseHamsterOvary: "batch.species.cho"
        case .pichiaPastoris: "batch.species.pichia"
        case .saccharomycesCerevisiae: "batch.species.saccharomyces"
        case .bacillusSubtilis: "batch.species.bacillus"
        case .clostridiumAcetobutylicum: "batch.species.clostridium"
        case .kluyveromycesLactis: "batch.species.kluyveromyces"
        case .pseudomonasFluorescens: "batch.species.pseudomonas"
        }
    }
}

extension StartCodonPolicy {
    var workspaceTitle: LocalizedStringResource {
        switch self {
        case .none: "batch.start.none"
        case .always: "batch.start.always"
        case .ifNotMethionine: "batch.start.ifNotMethionine"
        }
    }

    var workspaceHint: LocalizedStringResource {
        switch self {
        case .none: "batch.start.none.hint"
        case .always: "batch.start.always.hint"
        case .ifNotMethionine: "batch.start.ifNotMethionine.hint"
        }
    }
}

extension StopPolicy {
    var workspaceTitle: LocalizedStringResource {
        switch self {
        case .preserve: "batch.stop.preserve"
        case .add: "batch.stop.add"
        }
    }
}

extension ProteinImportSource {
    var workspaceTitle: LocalizedStringResource {
        switch self {
        case .paste(let line): "batch.source.paste \(line)"
        case .fasta(let line): "batch.source.fasta \(line)"
        case .spreadsheet(_, let sheet?, let row): "batch.source.sheet \(sheet) \(row)"
        case .spreadsheet(_, nil, let row): "batch.source.row \(row)"
        }
    }
}

extension ProteinImportRecordIssue {
    var workspaceMessage: LocalizedStringResource {
        switch self {
        case .missingCell(.name): "batch.error.missingNameCell"
        case .missingCell(.sequence): "batch.error.missingSequenceCell"
        case .input(let reason): reason.workspaceMessage
        }
    }
}

private extension RecordInputError {
    var workspaceMessage: LocalizedStringResource {
        switch self {
        case .invalidName: "batch.error.recordName"
        case .sequence(.empty): "batch.error.emptyProtein"
        case .sequence(.invalidResidue(let position)): "batch.error.invalidResidue \(position)"
        case .sequence(.misplacedStop(let position)): "batch.error.misplacedStop \(position)"
        case .sequence(.tooLong(let limit)): "batch.error.proteinLength \(limit)"
        case .sequence(.stopAdditionExceedsLimit(let limit)): "batch.error.addStopLimit \(limit)"
        }
    }
}

func workspaceMessage(for error: any Error) -> LocalizedStringResource {
    switch error {
    case SpreadsheetInputError.legacyWorkbook: "spreadsheet.error.legacy"
    case SpreadsheetInputError.unsupportedExtension: "spreadsheet.error.format"
    case SpreadsheetInputError.emptyFile, SpreadsheetReadError.emptyData: "spreadsheet.error.empty"
    case SpreadsheetInputError.fileTooLarge: "spreadsheet.error.size"
    case SpreadsheetReadError.invalidEncoding: "spreadsheet.error.encoding"
    case SpreadsheetReadError.malformedDelimitedText: "spreadsheet.error.delimited"
    case SpreadsheetReadError.invalidWorkbook: "spreadsheet.error.workbook"
    case SpreadsheetReadError.importLimitExceeded: "spreadsheet.error.limits"
    case LocalFileError.unsupportedFASTAExtension: "batch.error.fastaExtension"
    case FASTAReadError.fileTooLarge: "spreadsheet.error.size"
    case FASTAReadError.invalidUTF8: "batch.error.fastaEncoding"
    case FASTAReadError.containsNUL: "batch.error.fastaNul"
    case FASTAReadError.emptyInput: "batch.error.fastaEmpty"
    case FASTAReadError.sequenceBeforeHeader(let record, let line): "batch.error.fastaBeforeHeader \(record) \(line)"
    case FASTAReadError.malformedHeader(let record, let line): "batch.error.fastaHeader \(record) \(line)"
    case FASTAReadError.missingName(let record, let line): "batch.error.fastaName \(record) \(line)"
    case FASTAReadError.emptySequence(let record, let line): "batch.error.fastaSequence \(record) \(line)"
    case SpreadsheetMappingError.emptyWorksheet: "spreadsheet.sheetEmpty"
    case SpreadsheetMappingError.columnsMustDiffer: "batch.error.columnsMustDiffer"
    case SpreadsheetMappingError.columnOutOfBounds: "batch.error.columnOutOfBounds"
    case SpreadsheetMappingError.noDataRows: "batch.error.noDataRows"
    case SpreadsheetMappingError.worksheetOutOfBounds: "batch.error.worksheetOutOfBounds"
    case AvoidMotifsError.inputTooLong(let limit): "batch.error.motifLength \(limit)"
    case AvoidMotifsError.invalidMotif(let position): "batch.error.motifInvalid \(position)"
    case BatchInputError.invalidBatchName: "batch.error.batchName"
    case BatchInputError.recordCount(let limit): "batch.error.recordCount \(limit.lowerBound) \(limit.upperBound)"
    case BatchInputError.totalLengthExceedsLimit(let limit): "batch.error.totalLength \(limit)"
    case BatchInputError.textTooLarge: "spreadsheet.error.size"
    case BatchInputError.record(let location, let reason):
        "batch.error.record \(location.sourceRow ?? location.position) \(String(localized: reason.workspaceMessage))"
    case is CocoaError: "spreadsheet.error.read"
    default: "batch.error.unexpected"
    }
}
