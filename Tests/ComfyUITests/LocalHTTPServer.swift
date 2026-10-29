import Foundation
import Network
import os

/// Plain TCP listener on an ephemeral port of 127.0.0.1 that answers every connection with the
/// same raw HTTP response, then closes it. It never binds other interfaces, so no firewall
/// prompt or CI network policy gets in the way. Lets a test see what URLSession really does with a
/// response, such as a redirect, which `StubURLProtocol` cannot reproduce.
final class LocalHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private var listener: NWListener?
    private let response: Data
    private var requestCount = 0

    init(rawResponse: String) {
        response = Data(rawResponse.utf8)
    }

    /// Requests received so far, including any redirected follow-up to this server.
    var requests: Int { queue.sync { requestCount } }

    /// Starts listening and returns the bound port.
    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                self.requestCount += 1
                connection.send(content: self.response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                guard !resumed.withLock({ let was = $0; $0 = true; return was }) else { return }
                switch state {
                case .ready:
                    continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }
}
