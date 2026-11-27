import Foundation
import ProteinDomain
import ProteinService
import Testing

struct ResponseClassifierTests {
    @Test(arguments: ["1", #""1""#, "1.0", "1e+0"])
    func compatibleSuccessMarkersRequireLocalVerification(marker: String) throws {
        let sequence = try ProteinSequence("MA*")
        let result = classify("""
            {"success":\(marker),"seq":"atggcttaa"}
            """, against: sequence)
        guard case .completed(let dna, httpStatus: 200) = result else {
            Issue.record("Expected a verified success")
            return
        }
        #expect(dna.dna == "ATGGCTTAA")
        #expect(dna.sha256 == .hash("ATGGCTTAA"))
        #expect(dna.checks.hasTerminalStop)
        #expect(result.status == .completed)
        #expect(result.effect == .completed)
        #expect(result.attemptStatus == .completed)
        #expect(!result.shouldStopQueue)
    }

    @Test func prependedStartIsIncludedInForbiddenMotifValidation() throws {
        let result = classify(
            #"{"success":1,"seq":"GCTTAA"}"#, against: try ProteinSequence("A*"),
            avoiding: try AvoidMotifs("TGGC"), startPolicy: .always
        )
        expectCompletedFailure(result, reason: .invalidDNA(.forbiddenMotif("TGGC", orientation: .forward)))
    }

    @Test(arguments: ["0", #""0""#, "true", "null", "[1]", #""01""#])
    func presentButUnsuccessfulMarkersAreCompletedFailures(marker: String) throws {
        let result = classify("""
            {"success":\(marker),"seq":"ATG"}
            """, against: try ProteinSequence("M"))
        expectCompletedFailure(result, reason: .unsuccessful)
    }

    @Test(arguments: [#"{"success":1}"#, #"{"success":1,"seq":42}"#, #"{"success":1,"seq":null}"#])
    func missingOrWrongTypeSequenceIsACompletedFailure(json: String) throws {
        expectCompletedFailure(classify(json, against: try ProteinSequence("M")), reason: .invalidSequenceField)
    }

    @Test func returnedDNAIsNotTrusted() throws {
        let sequence = try ProteinSequence("MA*")
        expectCompletedFailure(
            classify(#"{"success":1,"seq":""}"#, against: sequence), reason: .invalidDNA(.emptyDNA)
        )
        expectCompletedFailure(
            classify(#"{"success":1,"seq":"ATGNGCTAA"}"#, against: sequence), reason: .invalidDNA(.invalidBase(position: 4))
        )
        expectCompletedFailure(
            classify(#"{"success":1,"seq":"ATGAAATAA"}"#, against: sequence),
            reason: .invalidDNA(.translationMismatch(position: 2, expected: "A", actual: "K"))
        )
        expectCompletedFailure(
            classify(#"{"success":1,"seq":"ATGGCTTAA"}"#, against: sequence, avoiding: try AvoidMotifs("GCCA")),
            reason: .invalidDNA(.forbiddenMotif("GCCA", orientation: .reverseComplement))
        )
    }

    @Test(arguments: [400, 401, 403, 404, 429])
    func clientRejectionsDoNotRequireJSON(status: Int) throws {
        let result = classify("not JSON", status: status, against: try ProteinSequence("M"))
        #expect(result == .rejected(httpStatus: status))
        #expect(result.status == .failed)
        #expect(result.attemptStatus == .failed)
        #expect(result.effect == .rejected)
        #expect(result.httpStatus == status)
        #expect(result.shouldStopQueue == [401, 403, 429].contains(status))
    }

    @Test(arguments: [301, 302, 307, 308, 408, 500, 503])
    func redirectsAndPotentialServerEffectsAreUnknown(status: Int) throws {
        expectUnknown(
            classify(#"{"success":1,"seq":"ATG"}"#, status: status, against: try ProteinSequence("M")),
            reason: .unexpectedHTTPStatus, httpStatus: status
        )
    }

    @Test(arguments: ["", " ", "{", "{bad json", #"{"success":1,"seq":"ATG",}"#,
                      #"{"success":1,"seq":"ATG","comment":01}"#, #"{"success":1,"seq":"ATG","comment":"\q"}"#])
    func missingOrMalformedJSONIsUnknown(json: String) throws {
        expectUnknown(classify(json, against: try ProteinSequence("M")), reason: .invalidJSON, httpStatus: 200)
    }

    @Test(arguments: ["[]", "[{}]", "null", "1", #""1""#])
    func nonObjectJSONIsUnknown(json: String) throws {
        expectUnknown(classify(json, against: try ProteinSequence("M")), reason: .nonObjectJSON, httpStatus: 200)
    }

    @Test func missingSuccessIsUnknown() throws {
        expectUnknown(
            classify(#"{"seq":"ATG"}"#, against: try ProteinSequence("M")), reason: .missingSuccess, httpStatus: 200
        )
    }

    @Test func chunksStopAtTheByteBudgetAndOversizeTakesPriority() throws {
        let sequence = try ProteinSequence("M")
        let receipt = Data(#"{"success":1,"seq":"ATG"}"#.utf8)
        var body = BoundedResponseBody()
        let firstChunkAccepted = body.append(receipt.prefix(12))
        let secondChunkAccepted = body.append(receipt.dropFirst(12))
        let paddingAccepted = body.append(Data(repeating: 32, count: 1_048_576 - receipt.count))
        #expect(firstChunkAccepted)
        #expect(secondChunkAccepted)
        #expect(paddingAccepted)
        #expect(ResponseClassifier.classify(httpStatus: 200, body: body, against: sequence).status == .completed)
        let excessAccepted = body.append(Data([32]))
        let subsequentChunkAccepted = body.append(receipt)
        #expect(!excessAccepted)
        #expect(!subsequentChunkAccepted)
        for status in [200, 429] {
            expectUnknown(
                ResponseClassifier.classify(httpStatus: status, body: body, against: sequence),
                reason: .oversizedResponse, httpStatus: status
            )
        }
    }

    @Test func JSONDepthBudgetCountsEachValueLevelNotStringContent() throws {
        let sequence = try ProteinSequence("M")
        let prefix = #"{"success":1,"seq":"ATG","comment":"[\"{\u0022}]","nested":"#
        func response(arrayDepth: Int) -> String {
            prefix + String(repeating: "[", count: arrayDepth) + "0" + String(repeating: "]", count: arrayDepth) + "}"
        }
        #expect(classify(response(arrayDepth: 30), against: sequence).status == .completed)
        expectUnknown(classify(response(arrayDepth: 31), against: sequence), reason: .jsonDepthLimitExceeded, httpStatus: 200)
    }

    @Test func JSONNodeBudgetCountsArrayElementsAndObjectValues() throws {
        let sequence = try ProteinSequence("M")
        func response(arrayElements: Int) -> String {
            #"{"success":1,"seq":"ATG","items":["# + String(repeating: "0,", count: arrayElements - 1) + "0]}"
        }
        #expect(classify(response(arrayElements: 249_996), against: sequence).status == .completed)
        expectUnknown(
            classify(response(arrayElements: 249_997), against: sequence), reason: .jsonNodeLimitExceeded, httpStatus: 200
        )
    }

    @Test func malformedUTF8InAnIgnoredFieldCannotCompleteAnAttempt() throws {
        var body = BoundedResponseBody()
        body.append(Data(#"{"success":1,"seq":"ATG","comment":""#.utf8))
        body.append(Data([255, 34, 125]))
        expectUnknown(
            ResponseClassifier.classify(httpStatus: 200, body: body, against: try ProteinSequence("M")),
            reason: .invalidJSON, httpStatus: 200
        )
    }

    @Test(arguments: [LocalDispatchRefusal.rejected, .cancelled, .stopped])
    func localRefusalBeforeDispatchIsKnownNotSubmitted(reason: LocalDispatchRefusal) {
        let result = ResponseClassifier.refusedBeforeDispatch(reason)
        #expect(result == .notSubmitted(reason))
        #expect(result.status == .failed)
        #expect(result.attemptStatus == .failed)
        #expect(result.effect == .notSubmitted)
        #expect(result.httpStatus == nil)
        #expect(result.shouldStopQueue)
    }

    @Test(arguments: [URLError.Code.timedOut, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                      .secureConnectionFailed, .serverCertificateUntrusted, .cancelled, .networkConnectionLost])
    func allTransportErrorsAfterDispatchAreUnknown(code: URLError.Code) {
        expectUnknown(
            ResponseClassifier.interruptedAfterDispatch(URLError(code)), reason: .transport(code), httpStatus: nil
        )
    }

    @Test func HTTPHeadersAloneDoNotProveAnInterruptedResponseCompleted() {
        expectUnknown(
            ResponseClassifier.interruptedAfterDispatch(URLError(.networkConnectionLost), httpStatus: 200),
            reason: .transport(.networkConnectionLost), httpStatus: 200
        )
        expectUnknown(ResponseClassifier.interruptedAfterDispatch(CancellationError()), reason: .transport(nil), httpStatus: nil)
    }

    private func classify(
        _ json: String, status: Int = 200, against sequence: ProteinSequence, avoiding motifs: AvoidMotifs = .empty,
        startPolicy: StartCodonPolicy = .none
    ) -> ServiceOutcome {
        var body = BoundedResponseBody()
        body.append(Data(json.utf8))
        return ResponseClassifier.classify(
            httpStatus: status, body: body, against: sequence, avoiding: motifs, startPolicy: startPolicy
        )
    }

    private func expectCompletedFailure(_ result: ServiceOutcome, reason: ReceiptFailure) {
        #expect(result == .failed(reason, httpStatus: 200))
        #expect(result.status == .failed)
        #expect(result.attemptStatus == .failed)
        #expect(result.effect == .completed)
        #expect(!result.shouldStopQueue)
    }

    private func expectUnknown(_ result: ServiceOutcome, reason: UnknownServiceEffect, httpStatus: Int?) {
        #expect(result == .unknown(reason, httpStatus: httpStatus))
        #expect(result.status == .unknown)
        #expect(result.attemptStatus == .unknown)
        #expect(result.effect == .unknown)
        #expect(result.httpStatus == httpStatus)
        #expect(result.shouldStopQueue)
    }
}
