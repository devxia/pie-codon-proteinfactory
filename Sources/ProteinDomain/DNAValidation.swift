import Foundation

public enum MotifOrientation: String, Equatable, Sendable {
    case forward, reverseComplement
}

public enum DNAValidationError: Error, Equatable, Sendable {
    case emptyDNA
    case invalidBase(position: Int)
    case incorrectLength(expected: Int, actual: Int)
    case translationMismatch(position: Int, expected: Character, actual: Character)
    case unexpectedStop(position: Int)
    case missingTerminalStop(position: Int)
    case forbiddenMotif(String, orientation: MotifOrientation)
}

public enum SavedDNAError: Error, Equatable, Sendable {
    case recordNotCompleted
    case missingDNAOrHash
    case hashMismatch
}

public struct DNAChecks: Equatable, Sendable {
    public let basePairCount: Int
    public let aminoAcidCount: Int
    public let gcPercent: Double
    public let hasTerminalStop: Bool
    public let checkedMotifCount: Int

    public init(basePairCount: Int, aminoAcidCount: Int, gcPercent: Double, hasTerminalStop: Bool, checkedMotifCount: Int) {
        self.basePairCount = basePairCount
        self.aminoAcidCount = aminoAcidCount
        self.gcPercent = gcPercent
        self.hasTerminalStop = hasTerminalStop
        self.checkedMotifCount = checkedMotifCount
    }
}

public struct VerifiedDNA: Equatable, Sendable {
    public let dna: String
    public let sha256: SHA256Digest
    public let checks: DNAChecks
}

public struct CodonComparison: Equatable, Identifiable, Sendable {
    public let position: Int
    public let expected: Character
    public let codon: String
    public let translated: Character?

    public var id: Int { position }
    /// Position zero is a DNA-only prefix; protein residue positions stay one-based.
    public var isPrependedStart: Bool { position == 0 }
}

public enum DNAValidation {
    private static let codonTable = Array((
        "KNKNTTTTRSRSIIMI" +
        "QHQHPPPPRRRRLLLL" +
        "EDEDAAAAGGGGVVVV" +
        "*Y*YSSSS*CWCLFLF"
    ).utf8)

    public static func verify(_ dna: String, against sequence: ProteinSequence, avoiding avoid: AvoidMotifs = .empty,
                              startPolicy: StartCodonPolicy = .none) throws -> VerifiedDNA {
        let length = dna.utf8.count
        guard length > 0 else { throw DNAValidationError.emptyDNA }
        let prefixLength = startPolicy.prependsATG(to: sequence) ? 3 : 0
        let expectedLength = sequence.value.utf8.count * 3 + prefixLength
        var bases: [DNABase] = []
        if length == expectedLength { bases.reserveCapacity(length) }
        for (index, byte) in dna.utf8.enumerated() {
            let uppercase = (97...122).contains(byte) ? byte - 32 : byte
            guard let base = DNABase(rawValue: uppercase) else { throw DNAValidationError.invalidBase(position: index + 1) }
            if length == expectedLength { bases.append(base) }
        }
        guard length == expectedLength else {
            throw DNAValidationError.incorrectLength(expected: expectedLength, actual: length)
        }
        if prefixLength == 3 {
            let actual = translatedBase(bases[0], bases[1], bases[2])
            guard actual == 77 else {
                throw DNAValidationError.translationMismatch(position: 0, expected: "M", actual: Character(Unicode.Scalar(actual)))
            }
        }
        for (index, expected) in sequence.value.utf8.enumerated() {
            let start = prefixLength + index * 3
            let actual = translatedBase(bases[start], bases[start + 1], bases[start + 2])
            guard expected != actual else { continue }
            let position = index + 1
            if actual == 42 { throw DNAValidationError.unexpectedStop(position: position) }
            if expected == 42 { throw DNAValidationError.missingTerminalStop(position: position) }
            throw DNAValidationError.translationMismatch(
                position: position, expected: Character(Unicode.Scalar(expected)), actual: Character(Unicode.Scalar(actual))
            )
        }

        let normalized = String(decoding: bases.map(\.rawValue), as: UTF8.self)
        for motif in avoid.motifs {
            if normalized.range(of: motif, options: .literal) != nil {
                throw DNAValidationError.forbiddenMotif(motif, orientation: .forward)
            }
            let complement = String(decoding: motif.utf8.reversed().compactMap { DNABase(rawValue: $0)?.complement.rawValue }, as: UTF8.self)
            if complement != motif, normalized.range(of: complement, options: .literal) != nil {
                throw DNAValidationError.forbiddenMotif(motif, orientation: .reverseComplement)
            }
        }

        let gc = bases.count(where: { $0 == .g || $0 == .c })
        return VerifiedDNA(dna: normalized, sha256: .hash(normalized), checks: DNAChecks(
            basePairCount: length,
            aminoAcidCount: sequence.residueCount,
            gcPercent: Double(gc) / Double(length) * 100,
            hasTerminalStop: sequence.hasTerminalStop,
            checkedMotifCount: avoid.motifs.count
        ))
    }

    public static func compareCodons(_ dna: String, with sequence: ProteinSequence,
                                     startPolicy: StartCodonPolicy = .none) throws -> [CodonComparison] {
        let prefixLength = startPolicy.prependsATG(to: sequence) ? 3 : 0
        let expectedLength = sequence.value.utf8.count * 3 + prefixLength
        let actualLength = dna.utf8.count
        guard actualLength == expectedLength else {
            throw DNAValidationError.incorrectLength(expected: expectedLength, actual: actualLength)
        }
        let bytes = Array(dna.utf8)
        func comparison(position: Int, expected: UInt8, start: Int) -> CodonComparison {
            let codon = bytes[start..<(start + 3)]
            let bases = codon.compactMap { DNABase(rawValue: (97...122).contains($0) ? $0 - 32 : $0) }
            let translated = bases.count == 3 ? Character(Unicode.Scalar(translatedBase(bases[0], bases[1], bases[2]))) : nil
            return CodonComparison(position: position, expected: Character(Unicode.Scalar(expected)),
                                   codon: String(decoding: codon, as: UTF8.self), translated: translated)
        }
        let prefix = prefixLength == 3 ? [comparison(position: 0, expected: 77, start: 0)] : []
        return prefix + sequence.value.utf8.enumerated().map { index, expected in
            comparison(position: index + 1, expected: expected, start: prefixLength + index * 3)
        }
    }

    private static func translatedBase(_ first: DNABase, _ second: DNABase, _ third: DNABase) -> UInt8 {
        codonTable[first.index * 16 + second.index * 4 + third.index]
    }

    public static func reverifyCompleted(_ record: SequenceRecord, avoiding avoid: AvoidMotifs,
                                         startPolicy: StartCodonPolicy = .none) throws -> VerifiedDNA {
        guard record.status == .completed else { throw SavedDNAError.recordNotCompleted }
        guard let dna = record.dna, let expectedHash = record.dnaSHA256 else { throw SavedDNAError.missingDNAOrHash }
        guard SHA256Digest.hash(dna) == expectedHash else { throw SavedDNAError.hashMismatch }
        return try verify(dna, against: record.sequence, avoiding: avoid, startPolicy: startPolicy)
    }
}

private enum DNABase: UInt8 {
    case a = 65, c = 67, g = 71, t = 84

    var index: Int {
        switch self {
        case .a: 0
        case .c: 1
        case .g: 2
        case .t: 3
        }
    }

    var complement: Self {
        switch self {
        case .a: .t
        case .c: .g
        case .g: .c
        case .t: .a
        }
    }
}
