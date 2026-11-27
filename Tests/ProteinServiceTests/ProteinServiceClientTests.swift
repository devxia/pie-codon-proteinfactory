import Foundation
import ProteinDomain
@testable import ProteinService
import Testing

@Suite(.serialized)
struct ProteinServiceClientTests {
    @Test func requestUsesFixedEndpointSubmittedSequenceAndFinalWireValues() async throws {
        let parameters = try OptimizationParameters(
            species: .escherichiaColi,
            stopPolicy: .add,
            avoid: AvoidMotifs("gaattc，GGT(A/T)ACC", enzymes: [.ecoRI, .bamHI])
        )
        let record = try makeRecord(name: "native-contract-smoke", sequence: "m", parameters: parameters)
        let client = makeClient(.response(chunks: [Data(#"{"success":1,"seq":"ATGTAA"}"#.utf8)]), timeout: 12.5)

        let outcome = await client.submit(record: record, parameters: parameters)

        #expect(outcome.status == .completed)
        #expect(MockURLProtocol.startCount == 1)
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url == Batch.serviceEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.timeoutInterval == 12.5)
        let body = try #require(MockURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "fileName": "native-contract-smoke",
            "jumpName": "pep",
            "sequence": "M*",
            "ignoreCodonQueue": "GAATTC,GGTAACC,GGTTACC,GGATCC",
            "speciesName": "Escherichia_coli",
        ])
        #expect(client.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(client.configuration.urlCache == nil)
        #expect(client.configuration.httpCookieStorage == nil)
        #expect(client.configuration.httpCookieAcceptPolicy == .never)
        #expect(!client.configuration.httpShouldSetCookies)
        #expect(client.configuration.urlCredentialStorage == nil)
        #expect(client.configuration.timeoutIntervalForRequest == 12.5)
        #expect(client.configuration.timeoutIntervalForResource == 12.5)
        #expect(!client.configuration.waitsForConnectivity)
    }

    @Test func preparedRequestDigestMatchesTransmittedBytesAndReceiptKeepsRawResponse() async throws {
        let response = Data(#"{ "success": 1, "seq": "ATG" }"#.utf8)
        let record = try makeRecord(name: "Record / 1")
        let request = try ProteinServiceRequest(record: record, parameters: .init())
        let client = makeClient(.response(chunks: [response]))

        let receipt = await client.submit(request)

        #expect(receipt.outcome.status == .completed)
        #expect(receipt.response == response)
        #expect(request.payloadSHA256 == .hash(try #require(MockURLProtocol.lastBody)))
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func startCodonPoliciesPrependATGWithoutChangingSubmittedProtein() async throws {
        for (policy, protein, serviceDNA, expectedDNA) in [
            (StartCodonPolicy.none, "A*", "GCTTAA", "GCTTAA"),
            (.always, "A*", "GCTTAA", "ATGGCTTAA"),
            (.ifNotMethionine, "A*", "GCTTAA", "ATGGCTTAA"),
            (.always, "M*", "ATGTAA", "ATGATGTAA"),
            (.ifNotMethionine, "M*", "ATGTAA", "ATGTAA")
        ] {
            let parameters = OptimizationParameters(startPolicy: policy)
            let record = try makeRecord(name: "start-policy", sequence: protein, parameters: parameters)
            let client = makeClient(.response(chunks: [Data("{\"success\":1,\"seq\":\"\(serviceDNA)\"}".utf8)]))
            let outcome = await client.submit(record: record, parameters: parameters)
            guard case .completed(let dna, httpStatus: 200) = outcome else {
                Issue.record("Expected a verified DNA result for \(policy) and \(protein)")
                return
            }
            #expect(dna.dna == expectedDNA)
            #expect(dna.sha256 == .hash(expectedDNA))
            #expect(dna.checks.basePairCount == expectedDNA.utf8.count)
            #expect(record.sequence.value == protein)
            let body = try #require(MockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["sequence"] == protein)
            #expect(json["startPolicy"] == nil)
        }
    }

    @Test func defaultTimeoutIsOneHundredTwentySeconds() {
        let client = ProteinServiceClient()
        #expect(client.configuration.timeoutIntervalForRequest == 120)
        #expect(client.configuration.timeoutIntervalForResource == 120)
    }

    @Test(arguments: Species.allCases)
    func speciesUsesItsApprovedWireValue(species: Species) async throws {
        let parameters = OptimizationParameters(species: species)
        let record = try makeRecord(parameters: parameters)
        let client = makeClient(.response(chunks: [Data(#"{"success":1,"seq":"ATG"}"#.utf8)]))

        _ = await client.submit(record: record, parameters: parameters)

        let body = try #require(MockURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["speciesName"] == species.wireValue)
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test(arguments: ["1", #""1""#])
    func numericAndStringSuccessUseTheExistingLocalVerification(marker: String) async throws {
        let record = try makeRecord()
        let client = makeClient(.response(chunks: [Data("{\"success\":\(marker),\"seq\":\"ATG\"}".utf8)]))

        let outcome = await client.submit(record: record, parameters: .init())

        guard case .completed(let dna, httpStatus: 200) = outcome else {
            Issue.record("Expected a verified transport success")
            return
        }
        #expect(dna.dna == "ATG")
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test(arguments: [
        #"{"success":0,"seq":"ATG"}"#,
        #"{"success":1}"#,
        #"{"success":1,"seq":"ATN"}"#,
        #"{"success":1,"seq":"ATGAAATAA"}"#,
    ])
    func completeUnsuccessfulReceiptsRemainFailures(json: String) async throws {
        let record = try makeRecord()
        let client = makeClient(.response(chunks: [Data(json.utf8)]))

        let outcome = await client.submit(record: record, parameters: .init())

        guard case .failed(_, httpStatus: 200) = outcome else {
            Issue.record("Expected a completed request with a failed receipt")
            return
        }
        #expect(outcome.effect == .completed)
        #expect(!outcome.shouldStopQueue)
    }

    @Test(arguments: [400, 401, 403, 404, 408, 429, 500, 503])
    func httpEffectsMatchTheExistingClassifier(status: Int) async throws {
        let record = try makeRecord()
        let client = makeClient(.response(status: status, chunks: [Data("not JSON".utf8)]))

        let outcome = await client.submit(record: record, parameters: .init())

        if (400..<500).contains(status), status != 408 {
            #expect(outcome == .rejected(httpStatus: status))
        } else {
            #expect(outcome == .unknown(.unexpectedHTTPStatus, httpStatus: status))
        }
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test(arguments: [301, 302, 307, 308])
    func redirectNegotiationIsRejectedBeforeAnyTargetRequest(status: Int) async throws {
        let record = try makeRecord()
        let target = URL(string: "https://example.invalid/redirect-target")!
        let client = makeClient(.redirect(status: status, target: target))

        let outcome = await client.submit(record: record, parameters: .init())

        #expect(MockURLProtocol.redirectNotificationCount == 1)
        #expect(MockURLProtocol.redirectedTargets == [target])
        #expect(MockURLProtocol.startCount == 1)
        #expect(MockURLProtocol.requestedURLs == [Batch.serviceEndpoint])
        #expect(outcome == .unknown(.unexpectedHTTPStatus, httpStatus: status))
    }

    @Test(arguments: ["", " ", "{", "{bad json", #"{"success":1,"seq":"ATG",}"#])
    func emptyAndMalformedJSONAreUnknown(json: String) async throws {
        let outcome = try await submitJSON(json)
        #expect(outcome == .unknown(.invalidJSON, httpStatus: 200))
    }

    @Test(arguments: ["[]", "[{}]", "null", "1", #""1""#])
    func nonObjectJSONIsUnknown(json: String) async throws {
        let outcome = try await submitJSON(json)
        #expect(outcome == .unknown(.nonObjectJSON, httpStatus: 200))
    }

    @Test func missingSuccessIsUnknown() async throws {
        let outcome = try await submitJSON(#"{"seq":"ATG"}"#)
        #expect(outcome == .unknown(.missingSuccess, httpStatus: 200))
    }

    @Test func streamedResponseStopsAboveOneMiB() async throws {
        let record = try makeRecord()
        let receipt = Data(#"{"success":1,"seq":"ATG"}"#.utf8)
        let client = makeClient(.response(chunks: [receipt, Data(repeating: 32, count: 1_048_576)]))

        let outcome = await client.submit(record: record, parameters: .init())

        #expect(outcome == .unknown(.oversizedResponse, httpStatus: 200))
        #expect(MockURLProtocol.startCount == 1)
        #expect(MockURLProtocol.stopCount == 1)
    }

    @Test func declaredOversizedResponseIsRefusedBeforeBodyDelivery() async throws {
        let record = try makeRecord()
        let client = makeClient(.response(
            headers: ["Content-Length": "1048577"],
            chunks: []
        ))

        let outcome = await client.submit(record: record, parameters: .init())

        #expect(outcome == .unknown(.oversizedResponse, httpStatus: 200))
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func JSONDepthBudgetIsAppliedAfterTransport() async throws {
        let json = #"{"success":1,"seq":"ATG","nested":"#
            + String(repeating: "[", count: 31) + "0" + String(repeating: "]", count: 31) + "}"
        let outcome = try await submitJSON(json)
        #expect(outcome == .unknown(.jsonDepthLimitExceeded, httpStatus: 200))
    }

    @Test func JSONNodeBudgetIsAppliedAfterTransport() async throws {
        let json = #"{"success":1,"seq":"ATG","items":["#
            + String(repeating: "0,", count: 249_996) + "0]}"
        let outcome = try await submitJSON(json)
        #expect(outcome == .unknown(.jsonNodeLimitExceeded, httpStatus: 200))
    }

    @Test(arguments: [
        URLError.Code.cannotFindHost,
        .dnsLookupFailed,
        .cannotConnectToHost,
        .secureConnectionFailed,
        .serverCertificateUntrusted,
        .networkConnectionLost,
    ])
    func dispatchedTransportFailuresAreUnknownWithoutRetry(code: URLError.Code) async throws {
        let record = try makeRecord()
        let client = makeClient(.failure(code))

        let outcome = await client.submit(record: record, parameters: .init())

        #expect(outcome == .unknown(.transport(code), httpStatus: nil))
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func injectedRequestTimeoutProducesUnknownWithoutRetry() async throws {
        let record = try makeRecord()
        let client = makeClient(
            .response(chunks: [Data(#"{"success":1,"seq":"ATG"}"#.utf8)], delay: 0.5),
            timeout: 0.05
        )

        let outcome = await client.submit(record: record, parameters: .init())

        #expect(outcome == .unknown(.transport(.timedOut), httpStatus: nil))
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func interruptionAfterResponseStartStaysUnknown() async throws {
        let record = try makeRecord()
        let client = makeClient(.failure(.networkConnectionLost, httpStatus: 200))

        let outcome = await client.submit(record: record, parameters: .init())

        guard case .unknown(.transport(.networkConnectionLost), _) = outcome else {
            Issue.record("Expected an unknown transport interruption")
            return
        }
        #expect(outcome.status == .unknown)
        #expect(outcome.effect == .unknown)
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func cancellationAfterResumeCancelsTheTaskAndIsUnknown() async throws {
        let started = AsyncSignal()
        let record = try makeRecord()
        let client = makeClient(
            .response(chunks: [Data(#"{"success":1,"seq":"ATG"}"#.utf8)], delay: 5),
            timeout: 10,
            onStart: { Task { await started.signal() } }
        )

        let task = Task { await client.submit(record: record, parameters: .init()) }
        await started.wait()
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .unknown(.transport(.cancelled), httpStatus: nil))
        #expect(MockURLProtocol.startCount == 1)
    }

    @Test func cancellationBeforeResumeIsNotSubmittedAndNeverStartsURLProtocol() async throws {
        let enteredGate = AsyncSignal()
        let releaseGate = AsyncSignal()
        let record = try makeRecord()
        let client = makeClient(.response(chunks: [Data(#"{"success":1,"seq":"ATG"}"#.utf8)]))

        let task = Task {
            await client.submit(record: record, parameters: .init()) {
                await enteredGate.signal()
                await releaseGate.wait()
                return nil
            }
        }
        await enteredGate.wait()
        task.cancel()
        await releaseGate.signal()
        let outcome = await task.value

        #expect(outcome == .notSubmitted(.cancelled))
        #expect(MockURLProtocol.startCount == 0)
    }

    @Test(arguments: [LocalDispatchRefusal.rejected, .cancelled, .stopped])
    func localGateRefusalsNeverResumeATask(reason: LocalDispatchRefusal) async throws {
        let record = try makeRecord()
        let client = makeClient(.response(chunks: [Data(#"{"success":1,"seq":"ATG"}"#.utf8)]))

        let outcome = await client.submit(record: record, parameters: .init()) { reason }

        #expect(outcome == .notSubmitted(reason))
        #expect(MockURLProtocol.startCount == 0)
    }

    private func makeClient(
        _ stub: MockStub,
        timeout: TimeInterval = 2,
        onStart: (@Sendable () -> Void)? = nil
    ) -> ProteinServiceClient {
        MockURLProtocol.reset(stub, onStart: onStart)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ProteinServiceClient(timeout: timeout, configuration: configuration)
    }

    private func makeRecord(
        name: String = "record",
        sequence: String = "M",
        parameters: OptimizationParameters = .init()
    ) throws -> SequenceRecord {
        try BatchPreparation.prepare(
            name: "batch",
            input: .text(sequence, singleRecordName: name),
            parameters: parameters
        ).records[0]
    }

    private func submitJSON(_ json: String) async throws -> ServiceOutcome {
        let record = try makeRecord()
        let client = makeClient(.response(chunks: [Data(json.utf8)]))
        let outcome = await client.submit(record: record, parameters: .init())
        #expect(MockURLProtocol.startCount == 1)
        return outcome
    }
}
