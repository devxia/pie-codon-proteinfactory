import Foundation
import ProteinDomain

public struct ProteinServiceRequest: Sendable {
    public let record: SequenceRecord
    public let parameters: OptimizationParameters
    public let payloadSHA256: SHA256Digest
    fileprivate let body: Data

    public init(record: SequenceRecord, parameters: OptimizationParameters) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(WireRequest(
            fileName: record.name,
            jumpName: "pep",
            sequence: record.sequence.value,
            ignoreCodonQueue: parameters.avoid.wireValue,
            speciesName: parameters.species.wireValue
        ))
        self.record = record
        self.parameters = parameters
        self.body = body
        self.payloadSHA256 = .hash(body)
    }
}

public struct ProteinServiceReceipt: Sendable {
    public let outcome: ServiceOutcome
    public let response: Data?

    public init(outcome: ServiceOutcome, response: Data? = nil) {
        self.outcome = outcome
        self.response = response
    }
}

public protocol ProteinSubmissionService: Sendable {
    func submit(_ request: ProteinServiceRequest) async -> ProteinServiceReceipt
}

public final class ProteinServiceClient: ProteinSubmissionService, @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 120

    let configuration: URLSessionConfiguration
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = ProteinServiceClient.defaultTimeout) {
        self.timeout = Self.validatedTimeout(timeout)
        configuration = Self.configure(.ephemeral, timeout: timeout)
    }

    init(timeout: TimeInterval = ProteinServiceClient.defaultTimeout, configuration: URLSessionConfiguration) {
        self.timeout = Self.validatedTimeout(timeout)
        self.configuration = Self.configure(configuration, timeout: timeout)
    }

    public func submit(
        record: SequenceRecord,
        parameters: OptimizationParameters,
        beforeDispatch: @Sendable () async -> LocalDispatchRefusal? = { nil }
    ) async -> ServiceOutcome {
        if let refusal = await beforeDispatch() {
            return ResponseClassifier.refusedBeforeDispatch(refusal)
        }
        guard !Task.isCancelled else { return ResponseClassifier.refusedBeforeDispatch(.cancelled) }
        guard let prepared = try? ProteinServiceRequest(record: record, parameters: parameters) else {
            return ResponseClassifier.refusedBeforeDispatch(.rejected)
        }
        return await submit(prepared).outcome
    }

    public func submit(_ prepared: ProteinServiceRequest) async -> ProteinServiceReceipt {
        guard !Task.isCancelled else {
            return ProteinServiceReceipt(outcome: ResponseClassifier.refusedBeforeDispatch(.cancelled))
        }
        let request = makeRequest(body: prepared.body)
        let collector = ResponseCollector()
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        let task = session.dataTask(with: request)
        collector.attach(session: session, task: task)

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                collector.start(continuation: continuation)
            }
        } onCancel: {
            collector.cancel()
        }

        switch result {
        case .response(let httpStatus, let body):
            let outcome = ResponseClassifier.classify(
                httpStatus: httpStatus, body: body, against: prepared.record.sequence, avoiding: prepared.parameters.avoid,
                startPolicy: prepared.parameters.startPolicy
            )
            return ProteinServiceReceipt(outcome: outcome, response: body.data)
        case .outcome(let outcome, let response):
            return ProteinServiceReceipt(outcome: outcome, response: response)
        }
    }

    private func makeRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: Batch.serviceEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    private static func configure(
        _ source: URLSessionConfiguration, timeout: TimeInterval
    ) -> URLSessionConfiguration {
        let configuration = source.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    private static func validatedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        precondition(timeout.isFinite && timeout > 0, "Timeout must be finite and positive")
        return timeout
    }
}

private struct WireRequest: Encodable {
    let fileName: String
    let jumpName: String
    let sequence: String
    let ignoreCodonQueue: String
    let speciesName: String
}

private enum TransportResult {
    case response(httpStatus: Int, body: BoundedResponseBody)
    case outcome(ServiceOutcome, response: Data?)
}

private final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<TransportResult, Never>?
    private var body = BoundedResponseBody()
    private var httpStatus: Int?
    private var exceededByteBudget = false
    private var resumed = false
    private var cancelledBeforeResume = false
    private var finished = false

    func attach(session: URLSession, task: URLSessionDataTask) {
        self.session = session
        self.task = task
    }

    func start(continuation: CheckedContinuation<TransportResult, Never>) {
        lock.lock()
        if cancelledBeforeResume {
            finished = true
            lock.unlock()
            session?.invalidateAndCancel()
            continuation.resume(returning: .outcome(ResponseClassifier.refusedBeforeDispatch(.cancelled), response: nil))
            return
        }
        self.continuation = continuation
        resumed = true
        task?.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if resumed {
            let task = self.task
            lock.unlock()
            task?.cancel()
            return
        }
        cancelledBeforeResume = true
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        finished = true
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(returning: .outcome(ResponseClassifier.refusedBeforeDispatch(.cancelled), response: nil))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        httpStatus = (response as? HTTPURLResponse)?.statusCode
        if response.expectedContentLength > Int64(BoundedResponseBody.maximumBytes) {
            exceededByteBudget = true
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let shouldCancel = !exceededByteBudget && !body.append(data)
        if shouldCancel { exceededByteBudget = true }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if httpStatus == nil {
            httpStatus = (task.response as? HTTPURLResponse)?.statusCode
        }
        let result: TransportResult
        if exceededByteBudget {
            result = .outcome(.unknown(.oversizedResponse, httpStatus: httpStatus), response: nil)
        } else if let error {
            result = .outcome(ResponseClassifier.interruptedAfterDispatch(error, httpStatus: httpStatus), response: body.data)
        } else if let httpStatus {
            result = .response(httpStatus: httpStatus, body: body)
        } else {
            result = .outcome(ResponseClassifier.interruptedAfterDispatch(URLError(.badServerResponse)), response: body.data)
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(returning: result)
    }
}
