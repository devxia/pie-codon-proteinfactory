public enum Species: String, CaseIterable, Sendable {
    case defaultD2P = "D2P(default)"
    case escherichiaColi = "Escherichia_coli"
    case chineseHamsterOvary = "Chinsese_hamster_ovary(CHO)_cells"
    case pichiaPastoris = "Pichia_pastoris"
    case saccharomycesCerevisiae = "Saccharomyces_cerevisiae"
    case bacillusSubtilis = "Bacillus_subtilis"
    case clostridiumAcetobutylicum = "Clostridium_acetobutylicum"
    case kluyveromycesLactis = "Kluyveromyces_lactis"
    case pseudomonasFluorescens = "Pseudomonas_fluorescens"

    public var wireValue: String { rawValue }

    public var displayName: String {
        switch self {
        case .defaultD2P: "D2P (default)"
        case .escherichiaColi: "Escherichia coli"
        case .chineseHamsterOvary: "Chinese hamster ovary (CHO) cells"
        case .pichiaPastoris: "Pichia pastoris"
        case .saccharomycesCerevisiae: "Saccharomyces cerevisiae"
        case .bacillusSubtilis: "Bacillus subtilis"
        case .clostridiumAcetobutylicum: "Clostridium acetobutylicum"
        case .kluyveromycesLactis: "Kluyveromyces lactis"
        case .pseudomonasFluorescens: "Pseudomonas fluorescens"
        }
    }
}

public enum StopPolicy: String, CaseIterable, Sendable {
    case preserve
    case add
}

public enum RestrictionEnzyme: String, CaseIterable, Sendable {
    case ecoRI = "EcoRI"
    case bamHI = "BamHI"
    case hindIII = "HindIII"
    case bsaI = "BsaI"
    case bsmBI = "BsmBI"
    case notI = "NotI"
    case ndeI = "NdeI"
    case xhoI = "XhoI"

    public var motif: String {
        switch self {
        case .ecoRI: "GAATTC"
        case .bamHI: "GGATCC"
        case .hindIII: "AAGCTT"
        case .bsaI: "GGTCTC"
        case .bsmBI: "CGTCTC"
        case .notI: "GCGGCCGC"
        case .ndeI: "CATATG"
        case .xhoI: "CTCGAG"
        }
    }
}

public enum AvoidMotifsError: Error, Equatable, Sendable {
    case inputTooLong(limit: Int)
    case invalidMotif(position: Int)
}

public struct AvoidMotifs: Equatable, Hashable, Sendable {
    public static let maximumCustomLength = 2_000
    public static let empty = Self(motifs: [])

    public let motifs: [String]
    public var wireValue: String { motifs.joined(separator: ",") }

    public init(_ custom: String, enzymes: [RestrictionEnzyme] = []) throws {
        guard custom.utf16.count <= Self.maximumCustomLength else {
            throw AvoidMotifsError.inputTooLong(limit: Self.maximumCustomLength)
        }
        var seen: Set<String> = []
        var normalized: [String] = []
        func append(_ motif: String) {
            if seen.insert(motif).inserted { normalized.append(motif) }
        }

        var compact = String.UnicodeScalarView()
        for scalar in custom.unicodeScalars where !isSequenceWhitespace(scalar) {
            compact.append(Unicode.Scalar(uppercaseASCII(scalar)) ?? scalar)
        }
        let tokens = compact.split { scalar in
            scalar == "," || scalar == "，" || scalar == ";" || scalar == "；"
        }
        for (index, token) in tokens.enumerated() {
            if token.elementsEqual("GGT(A/T)ACC".unicodeScalars) {
                append("GGTAACC")
                append("GGTTACC")
                continue
            }
            guard token.allSatisfy({ isUppercaseDNABase($0.value) }) else {
                throw AvoidMotifsError.invalidMotif(position: index + 1)
            }
            append(String(String.UnicodeScalarView(token)))
        }
        for enzyme in enzymes { append(enzyme.motif) }
        self.init(motifs: normalized)
    }

    public init(canonicalWireValue: String) throws {
        guard !canonicalWireValue.isEmpty else {
            self = .empty
            return
        }
        var seen: Set<String> = []
        var canonical: [String] = []
        for (index, token) in canonicalWireValue.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            let motif = String(token)
            guard !motif.isEmpty, motif.unicodeScalars.allSatisfy({ isUppercaseDNABase($0.value) }),
                  seen.insert(motif).inserted else {
                throw AvoidMotifsError.invalidMotif(position: index + 1)
            }
            canonical.append(motif)
        }
        self.init(motifs: canonical)
    }

    private init(motifs: [String]) {
        self.motifs = motifs
    }
}

public enum StartCodonPolicy: String, CaseIterable, Hashable, Sendable {
    case none
    case always
    case ifNotMethionine

    public static let codon = "ATG"

    /// The prefix is added to returned DNA only, never to the submitted protein.
    public func prependsATG(to sequence: ProteinSequence) -> Bool {
        switch self {
        case .none: false
        case .always: true
        case .ifNotMethionine: sequence.value.first != "M"
        }
    }
}

public struct OptimizationParameters: Equatable, Hashable, Sendable {
    public let species: Species
    public let startPolicy: StartCodonPolicy
    public let stopPolicy: StopPolicy
    public let avoid: AvoidMotifs

    public init(species: Species = .defaultD2P, startPolicy: StartCodonPolicy = .none,
                stopPolicy: StopPolicy = .preserve, avoid: AvoidMotifs = .empty) {
        self.species = species
        self.startPolicy = startPolicy
        self.stopPolicy = stopPolicy
        self.avoid = avoid
    }
}

func isUppercaseDNABase(_ value: UInt32) -> Bool {
    value == 65 || value == 67 || value == 71 || value == 84
}
