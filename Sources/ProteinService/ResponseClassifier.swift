import Foundation
import ProteinDomain

public enum ResponseClassifier {
    public static func classify(
        httpStatus: Int, body: BoundedResponseBody, against sequence: ProteinSequence, avoiding avoid: AvoidMotifs = .empty,
        startPolicy: StartCodonPolicy = .none
    ) -> ServiceOutcome {
        guard let data = body.data else { return .unknown(.oversizedResponse, httpStatus: httpStatus) }
        if (400..<500).contains(httpStatus), httpStatus != 408 {
            return .rejected(httpStatus: httpStatus)
        }
        guard (200..<300).contains(httpStatus) else {
            return .unknown(.unexpectedHTTPStatus, httpStatus: httpStatus)
        }

        let receipt: WireReceipt
        do {
            let isObject = try JSONPreflight.isObject(data)
            guard String(data: data, encoding: .utf8) != nil else {
                return .unknown(.invalidJSON, httpStatus: httpStatus)
            }
            guard isObject else { return .unknown(.nonObjectJSON, httpStatus: httpStatus) }
            receipt = try JSONDecoder().decode(WireReceipt.self, from: data)
        } catch JSONPreflight.Failure.depthLimitExceeded {
            return .unknown(.jsonDepthLimitExceeded, httpStatus: httpStatus)
        } catch JSONPreflight.Failure.nodeLimitExceeded {
            return .unknown(.jsonNodeLimitExceeded, httpStatus: httpStatus)
        } catch {
            return .unknown(.invalidJSON, httpStatus: httpStatus)
        }

        guard receipt.hasSuccess else { return .unknown(.missingSuccess, httpStatus: httpStatus) }
        guard receipt.isSuccess else { return .failed(.unsuccessful, httpStatus: httpStatus) }
        guard let serviceDNA = receipt.sequence else { return .failed(.invalidSequenceField, httpStatus: httpStatus) }
        let dna = startPolicy.prependsATG(to: sequence) ? StartCodonPolicy.codon + serviceDNA : serviceDNA
        do {
            return .completed(
                try DNAValidation.verify(dna, against: sequence, avoiding: avoid, startPolicy: startPolicy),
                httpStatus: httpStatus
            )
        } catch {
            return .failed(.invalidDNA(error as? DNAValidationError), httpStatus: httpStatus)
        }
    }

    public static func refusedBeforeDispatch(_ reason: LocalDispatchRefusal) -> ServiceOutcome {
        .notSubmitted(reason)
    }

    public static func interruptedAfterDispatch(_ error: any Error, httpStatus: Int? = nil) -> ServiceOutcome {
        .unknown(.transport((error as? URLError)?.code), httpStatus: httpStatus)
    }
}

private struct WireReceipt: Decodable {
    let hasSuccess: Bool
    let isSuccess: Bool
    let sequence: String?

    enum CodingKeys: String, CodingKey { case success, seq }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasSuccess = container.contains(.success)
        isSuccess = (try? container.decode(String.self, forKey: .success)) == "1"
            || (try? container.decode(Double.self, forKey: .success)) == 1
        sequence = isSuccess ? try? container.decode(String.self, forKey: .seq) : nil
    }
}
