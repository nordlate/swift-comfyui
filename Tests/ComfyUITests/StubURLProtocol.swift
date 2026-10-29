import Foundation

/// Intercepts every plain HTTP request made through `URLSession.shared` while registered and
/// answers from `handler`. Lets networking tests exercise the success path without a
/// server.
///
/// WebSocket handshakes are deliberately NOT intercepted: `URLSessionWebSocketTask` routes its
/// handshake through URLProtocol as an http(s) request carrying `Upgrade: websocket`, and
/// WebSocket tests need that to reach a real loopback listener (`LocalHTTPServer`).
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (statusCode: Int, body: Data))?
    /// When set, every request fails with this instead of answering, like a refused connection.
    nonisolated(unsafe) static var failure: URLError?

    /// Asks per request whether to hold its answer until `releaseHeld()`. The request stays
    /// pending without blocking the loading thread, so other requests are still answered.
    nonisolated(unsafe) static var shouldHold: (@Sendable (URLRequest) -> Bool)?
    /// Answers held requests (instead of `handler`), so a test can tell a held request's answer
    /// from the answers given meanwhile.
    nonisolated(unsafe) static var heldHandler: (@Sendable (URLRequest) -> (statusCode: Int, body: Data))?
    nonisolated(unsafe) private static var held: [StubURLProtocol] = []
    private static let heldLock = NSLock()

    private var loadingThread: Thread?
    private var isStopped = false

    /// Answers every held request that is still loading, in arrival order, on the thread that
    /// started it. Requests already stopped (cancelled) are skipped.
    static func releaseHeld() {
        for request in takeHeld() {
            guard let thread = request.loadingThread else { continue }
            request.perform(#selector(respondToHeld), on: thread, with: nil, waitUntilDone: false)
        }
    }

    /// Removes the held requests that are not stopped.
    private static func takeHeld() -> [StubURLProtocol] {
        heldLock.withLock {
            defer { held.removeAll() }
            return held.filter { !$0.isStopped }
        }
    }

    static func install(_ handler: @escaping @Sendable (URLRequest) -> (statusCode: Int, body: Data)) {
        self.handler = handler
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    static func installFailure(_ error: URLError) {
        failure = error
        install { _ in (500, Data()) }
    }

    static func uninstall() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        handler = nil
        failure = nil
        shouldHold = nil
        heldHandler = nil
        // Requests still held would otherwise stay pending until their timeout.
        for request in takeHeld() {
            guard let thread = request.loadingThread else { continue }
            request.perform(#selector(failHeld), on: thread, with: nil, waitUntilDone: false)
        }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard handler != nil else { return false }
        return request.value(forHTTPHeaderField: "Upgrade")?.lowercased() != "websocket"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, request.url != nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        loadingThread = Thread.current
        if Self.shouldHold?(request) == true {
            Self.heldLock.withLock { Self.held.append(self) }
            return
        }
        respond(with: handler)
    }

    @objc private func respondToHeld() {
        guard !Self.heldLock.withLock({ isStopped }) else { return }
        respond(with: Self.heldHandler ?? Self.handler)
    }

    @objc private func failHeld() {
        guard !Self.heldLock.withLock({ isStopped }) else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func respond(with handler: (@Sendable (URLRequest) -> (statusCode: Int, body: Data))?) {
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (statusCode, body) = handler(request)
        guard let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.heldLock.withLock { isStopped = true }
    }
}
