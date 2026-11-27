import CryptoKit
import Foundation

public struct SHA256Digest: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    public static func hash(_ text: String) -> Self {
        hash(Data(text.utf8))
    }

    public static func hash(_ bytes: Data) -> Self {
        let digits = Array("0123456789abcdef".utf8)
        let hex = SHA256.hash(data: bytes).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }
        return Self(hex: String(decoding: hex, as: UTF8.self))
    }

    private init(hex: String) {
        rawValue = hex
    }
}

public enum PreviewIntegrityError: Error, Equatable, Sendable {
    case endpointMismatch
    case fingerprintMismatch
    case recordLayoutMismatch(position: Int)
    case inputHashMismatch(position: Int)
}

public enum PreviewIntegrity {
    static func fingerprint(name: String, records: [SequenceRecord], parameters: OptimizationParameters, endpoint: URL) -> SHA256Digest {
        var bytes = Data()
        func append(_ field: String) {
            bytes.append(contentsOf: String(field.utf8.count).utf8)
            bytes.append(58)
            bytes.append(contentsOf: field.utf8)
        }
        // Existing batches with the default start policy keep their v1 fingerprint.
        // Adding DNA requires v2; an old fingerprint must never authorize that change.
        append(parameters.startPolicy == .none ? "ProteinDomain.preview.v1" : "ProteinDomain.preview.v2")
        append(name)
        append(endpoint.absoluteString)
        append(parameters.species.wireValue)
        if parameters.startPolicy != .none { append(parameters.startPolicy.rawValue) }
        append(parameters.stopPolicy.rawValue)
        append(parameters.avoid.wireValue)
        append(String(records.count))
        for record in records {
            append(record.name)
            append(record.originalSequence.value)
            append(record.sequence.value)
        }
        return .hash(bytes)
    }

    public static func verify(_ batch: Batch) throws {
        guard batch.endpoint.absoluteString == Batch.serviceEndpoint.absoluteString else {
            throw PreviewIntegrityError.endpointMismatch
        }
        for (index, record) in batch.records.enumerated() {
            let position = index + 1
            guard record.batchID == batch.id, record.position == position else {
                throw PreviewIntegrityError.recordLayoutMismatch(position: position)
            }
            guard SHA256Digest.hash(record.sequence.value) == record.inputSHA256 else {
                throw PreviewIntegrityError.inputHashMismatch(position: position)
            }
        }
        guard batch.fingerprint == fingerprint(name: batch.name, records: batch.records, parameters: batch.parameters, endpoint: batch.endpoint) else {
            throw PreviewIntegrityError.fingerprintMismatch
        }
    }
}
