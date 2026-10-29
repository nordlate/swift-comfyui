import Foundation
import os

/// The HTTP side of a ComfyUI server: system status, queueing prompts, uploads, history,
/// output downloads, cancellation and node options.
///
/// Every response body is read with a size limit, redirects are refused (reported as
/// ``ComfyUIError/redirected(to:)``), and every request runs under the client's
/// ``ComfyUIConnectionGrant``. A client is a small value: copies share the grant, so revoking it
/// stops all of them.
public struct ComfyUIClient: Sendable {
    let baseURL: URL
    /// Every request runs under this grant; revoking it ends this client's use, and that of every
    /// copy made from it.
    public let grant: ComfyUIConnectionGrant

    /// A client for `endpoint`. Pass the same `grant` to the clients of one connection so that
    /// revoking it ends them all; by default each client gets a grant of its own.
    public init(endpoint: ComfyUIEndpoint, grant: ComfyUIConnectionGrant = ComfyUIConnectionGrant()) {
        baseURL = endpoint.httpBaseURL
        self.grant = grant
    }

    // MARK: - Connection check

    /// `GET /system_stats` with a 5-second timeout: whether a ComfyUI server answers, and its version.
    public func checkConnection() async throws -> ComfyUISystemStats {
        let url = baseURL.appendingPathComponent("system_stats")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let data = try await boundedData(for: request, limit: Self.maxSmallResponseSize)
        return try JSONDecoder().decode(ComfyUISystemStats.self, from: data)
    }

    // MARK: - Queue a prompt

    /// Queues an API-format `workflow` (`POST /prompt`). `clientID` is the ID the WebSocket was
    /// opened with, so its progress events reach that socket. Each prompt asks for latent previews
    /// (`extra_data.preview_method = auto`), whatever the server was launched with.
    ///
    /// A workflow the server refuses throws ``ComfyUIError/promptRejected(statusCode:_:)``, whose
    /// ``ComfyUIPromptRejection`` names the failed nodes and inputs.
    public func queuePrompt(_ workflow: [String: ComfyUINode], clientID: String) async throws -> ComfyUIPromptResponse {
        let url = baseURL.appendingPathComponent("prompt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ComfyUIPromptRequest(prompt: workflow, clientID: clientID)
        request.httpBody = try JSONEncoder().encode(body)

        // A rejected workflow comes back as an error status whose body says which node and
        // input failed, so the status is checked after the body is read.
        let (data, response) = try await boundedResponse(for: request, limit: Self.maxSmallResponseSize, acceptsErrorStatus: true)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            if let rejection = ComfyUIPromptRejection(data: data) {
                throw ComfyUIError.promptRejected(statusCode: statusCode, rejection)
            }
            throw ComfyUIError.httpError(statusCode)
        }
        return try JSONDecoder().decode(ComfyUIPromptResponse.self, from: data)
    }

    // MARK: - Upload an image

    /// Largest image ``uploadImage(_:filename:)`` sends (64 MiB; a 4096×4096 PNG stays well under it).
    public static let maxUploadSize = 64 * 1024 * 1024

    /// Uploads a PNG into ComfyUI's input folder (`POST /upload/image`) and returns the name a
    /// `LoadImage` node reads it by. The server may rename the file to avoid a clash, so the name
    /// it reports is used, with its subfolder. Throws ``ComfyUIError/uploadTooLarge`` above
    /// ``maxUploadSize``.
    public func uploadImage(_ png: Data, filename: String) async throws -> String {
        guard png.count <= Self.maxUploadSize else { throw ComfyUIError.uploadTooLarge }
        let boundary = "ComfyUIBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("upload/image"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(png: png, filename: filename, boundary: boundary)

        let data = try await boundedData(for: request, limit: Self.maxSmallResponseSize)
        let uploaded = try JSONDecoder().decode(ComfyUIUploadResponse.self, from: data)
        guard !uploaded.name.isEmpty else { throw ComfyUIError.invalidResponse }
        return uploaded.subfolder.isEmpty ? uploaded.name : "\(uploaded.subfolder)/\(uploaded.name)"
    }

    static func multipartBody(png: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: image/png\r\n\r\n")
        body.append(png)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"type\"\r\n\r\ninput\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Get history for a prompt

    /// The history entry of `promptID` (`GET /history/{id}`). Throws
    /// ``ComfyUIError/promptNotFound(_:)`` when the server has no entry for it, which is also the
    /// case while it is still queued or running. ``ComfyUIHistoryEntry/outcome`` says whether it finished.
    public func getHistory(promptID: String) async throws -> ComfyUIHistoryEntry {
        let url = baseURL.appendingPathComponent("history/\(promptID)")
        let data = try await boundedData(for: URLRequest(url: url), limit: Self.maxJSONResponseSize)

        let history = try JSONDecoder().decode([String: ComfyUIHistoryEntry].self, from: data)
        guard let entry = history[promptID] else {
            throw ComfyUIError.promptNotFound(promptID)
        }
        return entry
    }

    // MARK: - Running and pending prompts

    /// The IDs of the prompts ComfyUI is running or has waiting (`GET /queue`).
    public func queuedPromptIDs() async throws -> Set<String> {
        let data = try await boundedData(for: URLRequest(url: baseURL.appendingPathComponent("queue")), limit: Self.maxJSONResponseSize)
        guard let queue = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComfyUIError.invalidResponse
        }
        // Each entry is `[number, prompt_id, prompt, ...]`.
        return Set(["queue_running", "queue_pending"].flatMap { key in
            (queue[key] as? [[Any]] ?? []).compactMap { $0.count > 1 ? $0[1] as? String : nil }
        })
    }

    // MARK: - Download an output image

    /// Largest output file ``downloadOutput(filename:subfolder:type:to:limit:)`` accepts (200 MiB).
    public static let maxDownloadSize = 200 * 1024 * 1024

    /// Streams one output file (`GET /view`) to `destination` and returns its size. The file is
    /// removed on failure or cancellation. A body larger than `limit` (never more than
    /// ``maxDownloadSize``) throws ``ComfyUIError/responseTooLarge``.
    ///
    /// - Parameters:
    ///   - filename: The image's `filename` from ``ComfyUIHistoryEntry/OutputImage``.
    ///   - subfolder: Its `subfolder`.
    ///   - type: Its `type`: `output` for saved images, `temp` for previews.
    ///   - destination: A file URL to create; it must not exist yet.
    ///   - limit: The most bytes to accept, such as what remains of a per-job budget.
    public func downloadOutput(
        filename: String, subfolder: String = "", type: String = "output", to destination: URL, limit: Int = maxDownloadSize
    ) async throws -> Int {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("view"), resolvingAgainstBaseURL: false) else {
            throw ComfyUIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "subfolder", value: subfolder),
            URLQueryItem(name: "type", value: type)
        ]
        guard let url = components.url else {
            throw ComfyUIError.invalidResponse
        }

        let limit = min(limit, Self.maxDownloadSize)
        do {
            return try await grant.run {
                try await BoundedResponse.download(
                    for: URLRequest(url: url), delegate: ComfyUIRedirectBlocker.shared, limit: limit,
                    to: destination, validate: Self.validateResponse
                )
            }
        } catch is BoundedResponse.TooLarge {
            throw ComfyUIError.responseTooLarge
        }
    }

    // MARK: - Cancel / interrupt

    /// Asks the server to interrupt `promptID` only (`POST /interrupt` with a `prompt_id` body).
    /// Servers that predate that body (such as v0.3.50) ignore it and interrupt whatever is
    /// running, so callers must only use this once the server is known to support the body
    /// (upstream ComfyUI v0.3.57 and later). There is deliberately no untargeted variant.
    public func interrupt(promptID: String) async throws {
        let url = baseURL.appendingPathComponent("interrupt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt_id": promptID])
        _ = try await boundedData(for: request, limit: Self.maxSmallResponseSize)
    }

    /// Removes a prompt that has not started yet from the queue (`POST /queue` with a `delete` body).
    public func deleteQueueItem(promptID: String) async throws {
        let url = baseURL.appendingPathComponent("queue")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["delete": [promptID]])
        _ = try await boundedData(for: request, limit: Self.maxSmallResponseSize)
    }

    // MARK: - Node info (available checkpoints, samplers, etc.)

    /// The choices a node offers for one of its required inputs (`GET /object_info/{class}`), such
    /// as the installed checkpoints for `CheckpointLoaderSimple`'s `ckpt_name`. Empty when the node
    /// or input is unknown or the input is not a list of choices.
    public func getInputOptions(for nodeClass: String, inputName: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent("object_info/\(nodeClass)")
        let data = try await boundedData(for: URLRequest(url: url), limit: Self.maxJSONResponseSize)

        let decoded = try JSONDecoder().decode([String: ComfyUINodeInfo].self, from: data)
        guard let nodeInfo = decoded[nodeClass],
              let inputDef = nodeInfo.input.required[inputName],
              let first = inputDef.first,
              case .array(let items) = first else {
            return []
        }

        return items.compactMap { item in
            if case .string(let s) = item { return s }
            return nil
        }
    }

    // MARK: - Helpers

    /// Status and queue replies are a few hundred bytes.
    static let maxSmallResponseSize = 1024 * 1024
    /// History (which embeds the submitted graph) and model lists; generous for real servers.
    static let maxJSONResponseSize = 32 * 1024 * 1024

    private func boundedData(for request: URLRequest, limit: Int) async throws -> Data {
        try await boundedResponse(for: request, limit: limit, acceptsErrorStatus: false).0
    }

    /// With `acceptsErrorStatus`, a 4xx/5xx body is returned for the caller to read.
    private func boundedResponse(for request: URLRequest, limit: Int, acceptsErrorStatus: Bool) async throws -> (Data, URLResponse) {
        do {
            return try await grant.run {
                try await BoundedResponse.data(
                    for: request, delegate: ComfyUIRedirectBlocker.shared, limit: limit,
                    validate: acceptsErrorStatus ? Self.rejectRedirects : Self.validateResponse
                )
            }
        } catch is BoundedResponse.TooLarge {
            throw ComfyUIError.responseTooLarge
        }
    }

    private static func validateResponse(_ response: URLResponse) throws {
        try rejectRedirects(response)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            throw ComfyUIError.httpError(statusCode)
        }
    }

    /// Accepts any HTTP status except a redirect, for callers that read error bodies.
    private static func rejectRedirects(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ComfyUIError.invalidResponse
        }
        // Redirects are refused (`ComfyUIRedirectBlocker`), so a 3xx arrives here as the response.
        if (300...399).contains(http.statusCode) {
            throw ComfyUIError.redirected(to: http.value(forHTTPHeaderField: "Location"))
        }
    }
}

/// Errors from ``ComfyUIClient`` and ``ComfyUIHistoryOutcome/requireSucceeded()``, with
/// messages that can be shown to the user.
public enum ComfyUIError: Error, LocalizedError {
    /// The response was not HTTP, or not the shape expected.
    case invalidResponse
    /// The server answered with this non-2xx status.
    case httpError(Int)
    /// `/prompt` refused the workflow; the rejection says which nodes and inputs failed.
    case promptRejected(statusCode: Int, ComfyUIPromptRejection)
    /// The server has no history entry for this prompt ID.
    case promptNotFound(String)
    /// The connection could not be used; the reason is shown as is.
    case connectionFailed(String)
    /// The response body exceeded the limit for its request.
    case responseTooLarge
    /// The server answered with a redirect, which is never followed; `to` is its `Location`.
    case redirected(to: String?)
    /// The request's ``ComfyUIConnectionGrant`` was revoked before, during or right after it.
    case connectionRevoked
    /// The prompt's history is not final yet; retrying may help.
    case historyIncomplete
    /// ComfyUI ended the prompt with an error or interruption.
    case executionFailed(String)
    /// The image is larger than ``ComfyUIClient/maxUploadSize``.
    case uploadTooLarge

    /// The message for a prompt ComfyUI reports as interrupted, from history or the WebSocket.
    public static let interruptedMessage = "The generation was interrupted in ComfyUI (for example from its own interface or by another client)."

    private static func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    /// A message for the user.
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from ComfyUI"
        case .httpError(let code): "ComfyUI returned HTTP \(code)"
        case .promptRejected(let statusCode, let rejection): rejection.description(statusCode: statusCode)
        case .promptNotFound(let id): "ComfyUI no longer has the result of prompt \(id). It was probably restarted."
        case .connectionFailed(let reason): "Connection failed: \(reason)"
        case .responseTooLarge: "Response from ComfyUI exceeded maximum allowed size"
        case .connectionRevoked: "The connection to ComfyUI was closed"
        case .redirected(let location):
            "The server redirected to \(location ?? "another address"), and redirects are not followed. "
                + "Enter the server's final address, and turn on TLS if it uses HTTPS."
        case .historyIncomplete: "ComfyUI has not finished recording this prompt yet"
        case .executionFailed(let message): message
        case .uploadTooLarge:
            "The image is larger than the app uploads to ComfyUI (\(Self.byteCount(ComfyUIClient.maxUploadSize))). Choose a smaller image size."
        }
    }
}
