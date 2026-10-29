import XCTest
@testable import ComfyUI

/// Host parsing, loopback detection, the transport rule and refused redirects.
@MainActor
final class ComfyUIEndpointTests: XCTestCase {

    override func tearDownWithError() throws {
        StubURLProtocol.uninstall()
    }

    // MARK: - Host field

    func testAcceptsHostNamesAndAddresses() {
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("localhost"), "localhost")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("  ComfyUI.Example.com. "), "comfyui.example.com")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("gpu-box"), "gpu-box")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("studio.local"), "studio.local")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("192.168.1.50"), "192.168.1.50")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("::1"), "::1")
        XCTAssertEqual(ComfyUIEndpoint.normalizedHost("[FD00::1]"), "fd00::1")
    }

    func testRejectsAnythingButAHost() {
        for text in [
            "", "   ", "http://192.168.1.50", "https://example.com", "user:pass@example.com", "user@example.com",
            "example.com/comfy", "example.com?x=1", "example.com#frag", "example.com:8188", "192.168.1.50:8188",
            "[::1]:8188", "exa mple.com", "example..com", ".example.com", "300.1.1.1", "[example.com]",
            "fe80::1%en0", "exämple.com"
        ] {
            XCTAssertNil(ComfyUIEndpoint.normalizedHost(text), "\(text) must be rejected")
        }
    }

    func testLoopbackHosts() {
        for host in ["localhost", "comfy.localhost", "127.0.0.1", "127.10.0.3", "::1", "::ffff:127.0.0.1"] {
            XCTAssertTrue(ComfyUIEndpoint.isLoopback(host), host)
        }
        for host in ["192.168.1.50", "10.0.0.1", "example.com", "localhost.example.com", "::2", "fd00::1", "::ffff:10.0.0.1"] {
            XCTAssertFalse(ComfyUIEndpoint.isLoopback(host), host)
        }
    }

    // MARK: - Transport rule

    func testLoopbackMayUsePlaintext() throws {
        for host in ["localhost", "127.0.0.1", "::1", "[::1]"] {
            let endpoint = try ComfyUIEndpoint(host: host, port: 8188, useTLS: false)
            XCTAssertEqual(endpoint.httpBaseURL.scheme, "http")
        }
    }

    func testRemotePlaintextIsAllowedWhenTLSIsOff() throws {
        for host in ["192.168.1.50", "gpu-box", "studio.local", "fd00::1"] {
            XCTAssertNoThrow(try ComfyUIEndpoint(host: host, port: 8188, useTLS: false), host)
            XCTAssertNoThrow(try ComfyUIEndpoint(host: host, port: 8188, useTLS: true), host)
        }
    }

    func testInternetHostsNeedTLS() throws {
        #if os(macOS)
        for host in ["gpu.example.com", "8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1"] {
            XCTAssertThrowsError(try ComfyUIEndpoint(host: host, port: 8188, useTLS: false)) {
                XCTAssertEqual($0 as? ComfyUIEndpoint.Failure, .plaintextBlockedByMacOS, host)
            }
        }
        #else
        // Elsewhere the app's own App Transport Security settings decide.
        XCTAssertNoThrow(try ComfyUIEndpoint(host: "gpu.example.com", port: 8188, useTLS: false))
        #endif
        for host in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.1.50", "169.254.1.1", "fd00::1", "fe80::1", "studio.local", "gpu-box"] {
            XCTAssertTrue(ComfyUIEndpoint.macOSAllowsPlaintext(to: host), host)
        }
        XCTAssertNoThrow(try ComfyUIEndpoint(host: "gpu.example.com", port: 8188, useTLS: true))
        XCTAssertNoThrow(try ComfyUIEndpoint(host: "localhost", port: 8188, useTLS: false))
    }

    func testURLsUseTheChosenTransportAndBracketIPv6() throws {
        let tls = try ComfyUIEndpoint(host: "gpu.example.com", port: 443, useTLS: true)
        XCTAssertEqual(tls.httpBaseURL.absoluteString, "https://gpu.example.com:443")
        XCTAssertEqual(tls.webSocketURL(clientID: "abc").absoluteString, "wss://gpu.example.com:443/ws?clientId=abc")

        let ipv6 = try ComfyUIEndpoint(host: "::1", port: 8188, useTLS: false)
        XCTAssertEqual(ipv6.httpBaseURL.absoluteString, "http://[::1]:8188")
        XCTAssertEqual(ipv6.webSocketURL(clientID: "abc").absoluteString, "ws://[::1]:8188/ws?clientId=abc")
        XCTAssertEqual(ipv6.httpBaseURL.appendingPathComponent("system_stats").absoluteString, "http://[::1]:8188/system_stats")
    }

    func testInvalidPortIsRejected() {
        XCTAssertThrowsError(try ComfyUIEndpoint(host: "localhost", port: 0, useTLS: false)) {
            XCTAssertEqual($0 as? ComfyUIEndpoint.Failure, .invalidPort)
        }
    }

    // MARK: - Redirects are refused

    func testHTTPRedirectIsReportedNotFollowed() async throws {
        let (server, port, redirectTarget) = try await redirectingServers()
        let client = ComfyUIClient(endpoint: try ComfyUIEndpoint(host: "127.0.0.1", port: port, useTLS: false))

        do {
            _ = try await client.checkConnection()
            XCTFail("a redirect must not be followed")
        } catch ComfyUIError.redirected(let location) {
            XCTAssertEqual(location?.hasSuffix("/elsewhere"), true)
        }
        XCTAssertEqual(server.requests, 1)
        XCTAssertEqual(redirectTarget.requests, 0)
    }

    func testWebSocketHandshakeRedirectIsNotFollowed() async throws {
        let (server, port, redirectTarget) = try await redirectingServers()
        let socket = ComfyUIWebSocket(
            endpoint: try ComfyUIEndpoint(host: "127.0.0.1", port: port, useTLS: false), clientID: "c"
        )

        var events: [ComfyUIProgressEvent] = []
        for await event in socket.events() { events.append(event) }

        guard case .redirected(let location)? = events.last else {
            return XCTFail("expected a redirect event, got \(events)")
        }
        XCTAssertEqual(location?.hasSuffix("/elsewhere"), true)
        XCTAssertEqual(server.requests, 1)
        XCTAssertEqual(redirectTarget.requests, 0)
    }
}

extension XCTestCase {
    /// A server that redirects to a second one (`target`); following the redirect would show up
    /// as a request to `target`.
    @MainActor
    func redirectingServers() async throws -> (redirecting: LocalHTTPServer, port: Int, target: LocalHTTPServer) {
        let target = LocalHTTPServer(rawResponse: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        let targetPort = try await target.start()
        addTeardownBlock { target.stop() }
        let redirecting = LocalHTTPServer(rawResponse:
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(targetPort)/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let port = try await redirecting.start()
        addTeardownBlock { redirecting.stop() }
        return (redirecting, port, target)
    }
}
