import Foundation

public enum ProteinDomainLimits {
    public static let maximumRecords = 200
    public static let maximumSequenceLength = 10_000
    public static let maximumBatchLength = 200_000
    public static let maximumTextBytes = 5 * 1024 * 1024
    public static let maximumAttempts = 10
}

public enum ProteinSequenceError: Error, Equatable, Sendable {
    case empty
    case invalidResidue(position: Int)
    case misplacedStop(position: Int)
    case tooLong(limit: Int)
    case stopAdditionExceedsLimit(limit: Int)
}

public struct ProteinSequence: Equatable, Hashable, Sendable {
    public let value: String
    public var hasTerminalStop: Bool { value.utf8.last == 42 }
    public var residueCount: Int { value.utf8.count - (hasTerminalStop ? 1 : 0) }

    private static let aminoAcids = Set("ACDEFGHIKLMNPQRSTVWY".unicodeScalars.map(\.value))

    public init(_ rawValue: String) throws {
        var residues: [UInt8] = []
        for scalar in rawValue.unicodeScalars where !isSequenceWhitespace(scalar) {
            let position = residues.count + 1
            if residues.last == 42 {
                throw ProteinSequenceError.misplacedStop(position: position - 1)
            }
            let residue = uppercaseASCII(scalar)
            if Self.aminoAcids.contains(residue) {
                residues.append(UInt8(residue))
            } else if residue == 42 {
                guard !residues.isEmpty else { throw ProteinSequenceError.misplacedStop(position: position) }
                residues.append(42)
            } else {
                throw ProteinSequenceError.invalidResidue(position: position)
            }
            guard residues.count <= ProteinDomainLimits.maximumSequenceLength else {
                throw ProteinSequenceError.tooLong(limit: ProteinDomainLimits.maximumSequenceLength)
            }
        }
        guard !residues.isEmpty else { throw ProteinSequenceError.empty }
        value = String(decoding: residues, as: UTF8.self)
    }

    private init(validated value: String) {
        self.value = value
    }

    public func applying(_ stopPolicy: StopPolicy) throws -> Self {
        guard stopPolicy == .add, !hasTerminalStop else { return self }
        guard value.utf8.count < ProteinDomainLimits.maximumSequenceLength else {
            throw ProteinSequenceError.stopAdditionExceedsLimit(limit: ProteinDomainLimits.maximumSequenceLength)
        }
        return Self(validated: value + "*")
    }
}

func isSequenceWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || scalar == "\u{FEFF}"
}

func uppercaseASCII(_ scalar: Unicode.Scalar) -> UInt32 {
    let value = scalar.value
    return (97...122).contains(value) ? value - 32 : value
}
