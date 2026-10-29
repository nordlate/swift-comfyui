import Foundation

/// Why a connection check failed, sorted into the cases the user can act on. Show
/// ``advice(host:)`` and keep the error's own message as detail.
public enum ComfyUIConnectionFailure: Equatable, Sendable {
    /// Nothing accepted the connection: ComfyUI isn't running, or listens only on its own computer.
    case notRunning
    /// The host name could not be resolved.
    case hostNotFound
    /// The server did not answer in time.
    case timedOut
    /// Something answered, but not with ComfyUI's `/system_stats`.
    case notComfyUI
    /// Anything else; its own message is shown as is.
    case other

    /// Classifies an error thrown by ``ComfyUIClient/checkConnection()``.
    public init(_ error: Error) {
        switch error {
        case let error as URLError:
            self.init(code: error.code)
        case is DecodingError:
            self = .notComfyUI
        case let error as ComfyUIError:
            switch error {
            case .httpError(404), .responseTooLarge, .invalidResponse: self = .notComfyUI
            default: self = .other
            }
        default:
            self = .other
        }
    }

    private init(code: URLError.Code) {
        switch code {
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: self = .notRunning
        case .cannotFindHost, .dnsLookupFailed: self = .hostNotFound
        case .timedOut: self = .timedOut
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData: self = .notComfyUI
        default: self = .other
        }
    }

    /// Plain advice for a server at `host`, or nil for ``other``.
    public func advice(host: String) -> String? {
        switch self {
        case .notRunning:
            guard let normalized = ComfyUIEndpoint.normalizedHost(host), !ComfyUIEndpoint.isLoopback(normalized) else {
                return "Couldn't connect. Is ComfyUI running?"
            }
            return "Couldn't connect to \(normalized). Is ComfyUI running? "
                + "For another computer, start ComfyUI there with --listen."
        case .hostNotFound:
            return "Couldn't find \(host). Check the host name."
        case .timedOut:
            return "No response. Check the host and port, and that the server is reachable from \(Self.thisDevice)."
        case .notComfyUI:
            return "This doesn't look like a ComfyUI server. Check the host and port."
        case .other:
            return nil
        }
    }

    #if os(macOS)
    private static let thisDevice = "this Mac"
    #else
    private static let thisDevice = "this device"
    #endif
}
