import Foundation

struct MockStub: Sendable {
    enum Behavior: Sendable {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(status: Int, target: URL)
        case failure(URLError.Code, httpStatus: Int?)
    }

    let behavior: Behavior
    let delay: TimeInterval

    init(behavior: Behavior, delay: TimeInterval = 0) {
        self.behavior = behavior
        self.delay = delay
    }

    static func response(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"],
        chunks: [Data],
        delay: TimeInterval = 0
    ) -> Self {
        .init(behavior: .response(status: status, headers: headers, chunks: chunks), delay: delay)
    }

    static func redirect(status: Int, target: URL) -> Self {
        .init(behavior: .redirect(status: status, target: target))
    }

    static func failure(_ code: URLError.Code, httpStatus: Int? = nil, delay: TimeInterval = 0) -> Self {
        .init(behavior: .failure(code, httpStatus: httpStatus), delay: delay)
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = State()
    private let workLock = NSLock()
    private var workItem: DispatchWorkItem?
    private var stopped = false

    static func reset(_ stub: MockStub = .failure(.badURL), onStart: (@Sendable () -> Void)? = nil) {
        state.reset(stub: stub, onStart: onStart)
    }

    static var startCount: Int { state.startCount }
    static var stopCount: Int { state.stopCount }
    static var redirectNotificationCount: Int { state.redirectNotificationCount }
    static var redirectedTargets: [URL] { state.redirectedTargets }
    static var requestedURLs: [URL] { state.requestedURLs }
    static var lastRequest: URLRequest? { state.lastRequest }
    static var lastBody: Data? { state.lastBody }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.start(request: request, body: Self.readBody(of: request))
        let work = DispatchWorkItem { [self] in
            workLock.lock()
            let shouldStop = stopped
            workLock.unlock()
            guard !shouldStop else { return }
            perform(stub.behavior)
        }
        workLock.lock()
        workItem = work
        workLock.unlock()
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: work)
        } else {
            work.perform()
        }
    }

    override func stopLoading() {
        workLock.lock()
        stopped = true
        workItem?.cancel()
        workLock.unlock()
        Self.state.stop()
    }

    private func perform(_ behavior: MockStub.Behavior) {
        switch behavior {
        case .response(let status, let headers, let chunks):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let status, let target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            Self.state.redirect(target: target)
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code, let httpStatus):
            if let httpStatus {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: httpStatus, httpVersion: "HTTP/1.1", headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("partial".utf8))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
                    workLock.lock()
                    let shouldStop = stopped
                    workLock.unlock()
                    guard !shouldStop else { return }
                    client?.urlProtocol(self, didFailWithError: URLError(code))
                }
            } else {
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
    }

    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stub = MockStub.failure(.badURL)
        private var onStart: (@Sendable () -> Void)?
        private var requests: [URLRequest] = []
        private var bodies: [Data?] = []
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var redirectNotificationCount = 0
        private(set) var redirectedTargets: [URL] = []

        var requestedURLs: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return requests.compactMap(\.url)
        }

        var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests.last
        }

        var lastBody: Data? {
            lock.lock()
            defer { lock.unlock() }
            return bodies.last ?? nil
        }

        func reset(stub: MockStub, onStart: (@Sendable () -> Void)?) {
            lock.lock()
            self.stub = stub
            self.onStart = onStart
            requests = []
            bodies = []
            startCount = 0
            stopCount = 0
            redirectNotificationCount = 0
            redirectedTargets = []
            lock.unlock()
        }

        func start(request: URLRequest, body: Data?) -> MockStub {
            lock.lock()
            requests.append(request)
            bodies.append(body)
            startCount += 1
            let stub = self.stub
            let onStart = self.onStart
            lock.unlock()
            onStart?()
            return stub
        }

        func redirect(target: URL) {
            lock.lock()
            redirectNotificationCount += 1
            redirectedTargets.append(target)
            lock.unlock()
        }

        func stop() {
            lock.lock()
            stopCount += 1
            lock.unlock()
        }
    }
}

actor AsyncSignal {
    private var signaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !signaled else { return }
        signaled = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}
