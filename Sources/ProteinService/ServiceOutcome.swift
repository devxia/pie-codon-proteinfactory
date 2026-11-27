import Foundation
import ProteinDomain

public enum ReceiptFailure: Equatable, Sendable {
    case unsuccessful, invalidSequenceField, invalidDNA(DNAValidationError?)
}

public enum UnknownServiceEffect: Equatable, Sendable {
    case unexpectedHTTPStatus, oversizedResponse, invalidJSON, nonObjectJSON, missingSuccess
    case jsonDepthLimitExceeded, jsonNodeLimitExceeded
    case transport(URLError.Code?)
}

public enum LocalDispatchRefusal: Equatable, Sendable {
    case rejected, cancelled, stopped
}

public enum ServiceOutcome: Equatable, Sendable {
    case completed(VerifiedDNA, httpStatus: Int)
    case failed(ReceiptFailure, httpStatus: Int)
    case rejected(httpStatus: Int)
    case notSubmitted(LocalDispatchRefusal)
    case unknown(UnknownServiceEffect, httpStatus: Int?)

    public var status: RecordStatus {
        switch self {
        case .completed: .completed
        case .failed, .rejected, .notSubmitted: .failed
        case .unknown: .unknown
        }
    }

    public var attemptStatus: AttemptStatus {
        switch self {
        case .completed: .completed
        case .failed, .rejected, .notSubmitted: .failed
        case .unknown: .unknown
        }
    }

    public var effect: RequestEffect {
        switch self {
        case .completed, .failed: .completed
        case .rejected: .rejected
        case .notSubmitted: .notSubmitted
        case .unknown: .unknown
        }
    }

    public var shouldStopQueue: Bool {
        switch self {
        case .unknown, .notSubmitted: true
        case .rejected(let status): status == 401 || status == 403 || status == 429
        case .completed, .failed: false
        }
    }

    public var httpStatus: Int? {
        switch self {
        case .completed(_, let status), .failed(_, let status), .rejected(let status): status
        case .unknown(_, let status): status
        case .notSubmitted: nil
        }
    }
}
