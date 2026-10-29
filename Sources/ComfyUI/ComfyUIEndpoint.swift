import Darwin
import Foundation
import os

/// A validated ComfyUI server address and the transport used to reach it.
///
/// Loopback servers may use plain HTTP/WS. Any other host uses TLS unless the caller turns it
/// off, which stands for the user's consent to unencrypted connections. There is no automatic
/// downgrade: a TLS failure is reported, never retried without TLS. On macOS, plaintext is also
/// refused up front for hosts App Transport Security would block (see ``macOSAllowsPlaintext(to:)``).
public struct ComfyUIEndpoint: Equatable, Sendable {
    /// Host name or IP address, lowercased, without brackets for IPv6.
    public let host: String
    /// TCP port, 1–65535.
    public let port: Int
    /// Whether requests use HTTPS and WSS.
    public let usesTLS: Bool

    /// Why an endpoint could not be made.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The host field holds more than a host name or IP address.
        case invalidHost
        /// The port is outside 1–65535.
        case invalidPort
        /// App Transport Security refuses plain HTTP/WS to internet names and public addresses,
        /// whatever the user chose. Thrown on macOS only.
        case plaintextBlockedByMacOS

        /// A message for the user.
        public var errorDescription: String? {
            switch self {
            case .invalidHost:
                "Enter only a host name or IP address, without http://, a user name, a path or a port."
            case .invalidPort:
                "Enter a port between 1 and 65535."
            case .plaintextBlockedByMacOS:
                "macOS allows unencrypted connections only to private network addresses (such as 192.168.x.x or 10.x.x.x), .local names and single-word host names. Turn on TLS for this server."
            }
        }
    }

    /// Validates a server address.
    ///
    /// - Parameters:
    ///   - rawHost: A host name or IP address as the user typed it; see ``normalizedHost(_:)``.
    ///   - port: The server's port (ComfyUI's default is 8188).
    ///   - useTLS: Whether to use HTTPS and WSS. Turning it off for a host other than this
    ///     computer is the consent to unencrypted connections.
    public init(host rawHost: String, port: Int, useTLS: Bool) throws(Failure) {
        guard let host = Self.normalizedHost(rawHost) else { throw .invalidHost }
        guard (1...65_535).contains(port) else { throw .invalidPort }
        #if os(macOS)
        if !useTLS && !Self.isLoopback(host) && !Self.macOSAllowsPlaintext(to: host) {
            throw .plaintextBlockedByMacOS
        }
        #endif
        self.host = host
        self.port = port
        self.usesTLS = useTLS
    }

    /// The HTTP(S) root of the server, such as `http://127.0.0.1:8188`.
    public var httpBaseURL: URL { url(scheme: usesTLS ? "https" : "http", path: "") }

    func webSocketURL(clientID: String) -> URL {
        url(scheme: usesTLS ? "wss" : "ws", path: "/ws", query: [URLQueryItem(name: "clientId", value: clientID)])
    }

    private func url(scheme: String, path: String, query: [URLQueryItem]? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        // URLComponents wants an IPv6 literal in brackets; `host` is validated, so this is total.
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = path
        components.queryItems = query
        guard let url = components.url else {
            preconditionFailure("A validated ComfyUI endpoint always forms a URL")
        }
        return url
    }

    // MARK: - Host rules

    /// The host as it will be used (trimmed and lowercased), or nil if the field holds anything
    /// but a host: a scheme, credentials, a path, a query, a fragment, a port or whitespace.
    /// IPv6 literals may be given with or without brackets.
    public static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // inet_pton accepts IPv6 zone IDs ("fe80::1%en0"), which a URL cannot carry unescaped.
        guard !host.contains("%") else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard ipv6Bytes(host) != nil else { return nil }
            return host.lowercased()
        }
        guard !host.isEmpty else { return nil }
        if host.contains(":") {
            // Only an IPv6 literal contains a colon; "host:8188" and "http://host" do not parse.
            guard ipv6Bytes(host) != nil else { return nil }
            return host.lowercased()
        }
        // A DNS name or IPv4 address: letters, digits, hyphens, underscores and dots, with no
        // empty labels. Anything else (/, ?, #, @, %, spaces, non-ASCII) is rejected.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }), name.count <= 253 else { return nil }
        // All-numeric names are IPv4 addresses and must be valid ones ("300.1.1.1" is not a host).
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            guard ipv4Bytes(name) != nil else { return nil }
        }
        return name.lowercased()
    }

    /// Whether `host` is this computer: `localhost`, 127.0.0.0/8, `::1` and IPv4-mapped 127.x addresses.
    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if let bytes = ipv4Bytes(host) { return bytes[0] == 127 }
        if let bytes = ipv6Bytes(host) {
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
            let mappedPrefix = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF]
            return Array(bytes.prefix(12)) == mappedPrefix && bytes[12] == 127
        }
        return false
    }

    /// Whether macOS lets an app without App Transport Security exceptions reach `host` (a
    /// normalized host) over plain HTTP/WS: private and link-local addresses (10/8, 172.16/12,
    /// 192.168/16, 169.254/16, fc00::/7, fe80::/10), `.local` names and unqualified
    /// (single-label) names. Public addresses, CGNAT 100.64/10 and qualified internet names are refused.
    public static func macOSAllowsPlaintext(to host: String) -> Bool {
        if let bytes = ipv4Bytes(host) {
            return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let bytes = ipv6Bytes(host) {
            return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
        }
        return host.hasSuffix(".local") || !host.contains(".")
    }

    private static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}

/// Refuses every HTTP redirect for ComfyUI requests and the WebSocket handshake, so a server
/// or proxy cannot move a connection to another host or from HTTPS to HTTP. The 3xx response
/// is returned instead and reported as `ComfyUIError.redirected`.
final class ComfyUIRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ComfyUIRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Permission for one connection's requests. Every ``ComfyUIClient`` made with the grant, and
/// every copy of those, shares it, so revoking it stops them all, including copies an operation
/// holds across awaits: new requests are refused and running ones are cancelled, both with
/// ``ComfyUIError/connectionRevoked``.
///
/// Use one grant per connection and revoke it when the user disconnects or the connection
/// settings change, so no request outlives the connection it was made for.
public final class ComfyUIConnectionGrant: Sendable {
    private struct State {
        var isRevoked = false
        var running: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A grant that is not revoked.
    public init() {}

    /// Whether ``revoke()`` has been called.
    public var isRevoked: Bool { state.withLock { $0.isRevoked } }

    /// Ends the grant: cancels its running requests and refuses new ones. Cannot be undone.
    public func revoke() {
        let cancels = state.withLock { state -> [@Sendable () -> Void] in
            state.isRevoked = true
            defer { state.running.removeAll() }
            return Array(state.running.values)
        }
        cancels.forEach { $0() }
    }

    /// Runs `operation` as a request of this connection, cancelling it if the grant is revoked
    /// before it finishes. Throws `ComfyUIError.connectionRevoked` whenever the grant is
    /// revoked, whether before, during or right after the request.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !isRevoked else { throw ComfyUIError.connectionRevoked }
        let task = Task { try await operation() }
        let id = UUID()
        let registered = state.withLock { state -> Bool in
            guard !state.isRevoked else { return false }
            state.running[id] = { task.cancel() }
            return true
        }
        guard registered else {
            task.cancel()
            throw ComfyUIError.connectionRevoked
        }
        defer { _ = state.withLock { $0.running.removeValue(forKey: id) } }

        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !isRevoked else { throw ComfyUIError.connectionRevoked }
            return value
        } catch {
            if isRevoked { throw ComfyUIError.connectionRevoked }
            throw error
        }
    }
}
