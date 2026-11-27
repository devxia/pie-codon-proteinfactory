import Foundation

public enum BatchStatus: String, CaseIterable, Sendable {
    case prepared, queued, running, completed, partial, failed, stopped, unknown
}

public enum RecordStatus: String, CaseIterable, Sendable {
    case pending, running, completed, failed, unknown
}

public enum AttemptStatus: String, CaseIterable, Sendable {
    case dispatching, completed, failed, unknown
}

public enum RequestEffect: String, CaseIterable, Sendable {
    case unknown, completed, rejected
    case notSubmitted = "not_submitted"
}

public struct RequestAttempt: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let number: Int
    public let startedAt: Date
    public let payloadSHA256: SHA256Digest
    public var finishedAt: Date?
    public var status: AttemptStatus
    public var effect: RequestEffect
    public var httpStatus: Int?
    public var elapsedMilliseconds: Int?
    public var response: Data?
    public var error: String?

    public init(
        id: UUID = UUID(), number: Int, startedAt: Date, payloadSHA256: SHA256Digest,
        finishedAt: Date? = nil, status: AttemptStatus = .dispatching, effect: RequestEffect = .unknown,
        httpStatus: Int? = nil, elapsedMilliseconds: Int? = nil, response: Data? = nil, error: String? = nil
    ) {
        self.id = id
        self.number = number
        self.startedAt = startedAt
        self.payloadSHA256 = payloadSHA256
        self.finishedAt = finishedAt
        self.status = status
        self.effect = effect
        self.httpStatus = httpStatus
        self.elapsedMilliseconds = elapsedMilliseconds
        self.response = response
        self.error = error
    }
}

public struct SequenceRecord: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let batchID: UUID
    public let position: Int
    public let name: String
    public let originalSequence: ProteinSequence
    public let sequence: ProteinSequence
    public let inputSHA256: SHA256Digest
    public var status: RecordStatus
    public var dna: String?
    public var dnaSHA256: SHA256Digest?
    public var checks: DNAChecks?
    public var error: String?
    public var attempts: [RequestAttempt]

    public init(
        id: UUID = UUID(), batchID: UUID, position: Int, name: String, originalSequence: ProteinSequence,
        sequence: ProteinSequence, inputSHA256: SHA256Digest, status: RecordStatus = .pending,
        dna: String? = nil, dnaSHA256: SHA256Digest? = nil, checks: DNAChecks? = nil,
        error: String? = nil, attempts: [RequestAttempt] = []
    ) {
        self.id = id
        self.batchID = batchID
        self.position = position
        self.name = name
        self.originalSequence = originalSequence
        self.sequence = sequence
        self.inputSHA256 = inputSHA256
        self.status = status
        self.dna = dna
        self.dnaSHA256 = dnaSHA256
        self.checks = checks
        self.error = error
        self.attempts = attempts
    }
}

public struct Batch: Equatable, Identifiable, Sendable {
    public static let serviceEndpoint = URL(string: "https://www.ourproteinfactory.com/toDnaAjaxCodon")!

    public let id: UUID
    public let requestID: String
    public let name: String
    public let parameters: OptimizationParameters
    public let endpoint: URL
    public let fingerprint: SHA256Digest
    public let createdAt: Date
    public var updatedAt: Date
    public var authorizedAt: Date?
    public var status: BatchStatus
    public var stopRequested: Bool
    public var message: String
    public var records: [SequenceRecord]

    public init(
        id: UUID, requestID: String, name: String, parameters: OptimizationParameters, endpoint: URL,
        fingerprint: SHA256Digest, records: [SequenceRecord], createdAt: Date, updatedAt: Date,
        authorizedAt: Date? = nil, status: BatchStatus = .prepared, stopRequested: Bool = false, message: String = ""
    ) {
        self.id = id
        self.requestID = requestID
        self.name = name
        self.parameters = parameters
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.records = records
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.authorizedAt = authorizedAt
        self.status = status
        self.stopRequested = stopRequested
        self.message = message
    }

    public var originalSequenceLength: Int {
        records.reduce(0) { $0 + $1.originalSequence.value.utf8.count }
    }

    public var submittedSequenceLength: Int {
        records.reduce(0) { $0 + $1.sequence.value.utf8.count }
    }
}
