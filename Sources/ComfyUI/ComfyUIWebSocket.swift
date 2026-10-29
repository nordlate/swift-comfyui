import Foundation
import os

/// ComfyUI's WebSocket (`/ws`): queue, progress, preview and completion events for the
/// prompts queued with the same client ID.
///
/// The handshake uses the endpoint's transport and refuses redirects, like ``ComfyUIClient``.
/// Each message is limited to 10 MB, and events are handed over through a bounded queue, so a
/// consumer that falls behind sees the newest preview rather than every one.
public final class ComfyUIWebSocket: Sendable {
    let url: URL

    /// A socket for `endpoint`. `clientID` must be the one passed to
    /// ``ComfyUIClient/queuePrompt(_:clientID:)`` for that prompt's events to arrive here.
    /// Nothing connects until ``events()`` is called.
    public init(endpoint: ComfyUIEndpoint, clientID: String) {
        url = endpoint.webSocketURL(clientID: clientID)
    }

    /// Connects and returns the server's events in order. The stream ends after a
    /// ``ComfyUIProgressEvent/disconnected(reason:)`` or ``ComfyUIProgressEvent/redirected(location:)``
    /// event; cancelling the iterating task closes the socket. Each call opens a new connection.
    ///
    /// When too many events pile up unread, routine ones are dropped (progress and queue updates
    /// coalesce, only the newest preview is kept); if even job-ending events no longer fit, the
    /// stream ends with `.disconnected`, so the consumer reconnects and checks the history.
    public func events() -> AsyncStream<ComfyUIProgressEvent> {
        let channel = ComfyUIEventChannel()
        let task = URLSession.shared.webSocketTask(with: url)
        // Same rule as the HTTP client: a redirected handshake fails instead of being followed.
        task.delegate = ComfyUIRedirectBlocker.shared
        task.maximumMessageSize = Self.maxPreviewSize
        task.resume()

        Logger.comfyUIClient.info("WebSocket connecting to \(self.url.absoluteString, privacy: .public)")

        let receiveLoop = Task {
            await self.receiveMessages(task: task, channel: channel)
        }

        return AsyncStream(unfolding: { await channel.next() }, onCancel: {
            receiveLoop.cancel()
            task.cancel(with: .normalClosure, reason: nil)
            Logger.comfyUIClient.info("WebSocket disconnected")
        })
    }

    private func receiveMessages(task: URLSessionWebSocketTask, channel: ComfyUIEventChannel) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if let event = parseMessage(message) {
                    await channel.send(event)
                }
                // Closed by overflow: end the connection so the consumer recovers.
                if await channel.isClosed {
                    task.cancel(with: .goingAway, reason: nil)
                    break
                }
            } catch {
                if !Task.isCancelled {
                    Logger.comfyUIClient.error("WebSocket error: \(error.localizedDescription, privacy: .public)")
                    // A refused redirect surfaces only as a generic handshake failure; the
                    // handshake response says where the server wanted to go.
                    if let http = task.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
                        await channel.send(.redirected(location: http.value(forHTTPHeaderField: "Location")))
                    } else {
                        await channel.send(.disconnected(reason: error.localizedDescription))
                    }
                }
                break
            }
        }
        await channel.finish()
    }

    /// Maximum preview image size (10 MB) to guard against memory exhaustion.
    private static let maxPreviewSize = 10 * 1024 * 1024

    /// ComfyUI binary messages carry a small header before the image bytes.
    /// Scan for JPEG (FF D8) or PNG (89 50 4E 47) magic within the first 16 bytes.
    private func parsePreviewImage(_ data: Data) -> ComfyUIProgressEvent? {
        guard data.count <= Self.maxPreviewSize else {
            Logger.comfyUIClient.warning("Dropping oversized preview (\(data.count) bytes)")
            return nil
        }
        let jpegMagic: [UInt8] = [0xFF, 0xD8]
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let scanLimit = min(data.count, 16)

        for offset in 0..<scanLimit {
            if offset + jpegMagic.count <= data.count,
               data[data.startIndex + offset] == jpegMagic[0],
               data[data.startIndex + offset + 1] == jpegMagic[1] {
                return .preview(data.suffix(from: data.startIndex + offset))
            }
            if offset + pngMagic.count <= data.count,
               data[data.startIndex + offset] == pngMagic[0],
               data[data.startIndex + offset + 1] == pngMagic[1],
               data[data.startIndex + offset + 2] == pngMagic[2],
               data[data.startIndex + offset + 3] == pngMagic[3] {
                return .preview(data.suffix(from: data.startIndex + offset))
            }
        }
        return nil
    }

    private func parseMessage(_ message: URLSessionWebSocketTask.Message) -> ComfyUIProgressEvent? {
        if case .data(let binary) = message {
            return parsePreviewImage(binary)
        }

        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              let payload = json["data"] as? [String: Any] else {
            return nil
        }

        switch type {
        case "status":
            if let queue = payload["status"] as? [String: Any],
               let remaining = queue["exec_info"] as? [String: Any],
               let count = remaining["queue_remaining"] as? Int {
                return .queueRemaining(count)
            }

        case "progress":
            let step = payload["value"] as? Int ?? 0
            let total = payload["max"] as? Int ?? 0
            let node = payload["node"] as? String
            let promptID = payload["prompt_id"] as? String ?? ""
            return .progress(promptID: promptID, node: node, step: step, total: total)

        case "executing":
            let nodeID = payload["node"] as? String
            let promptID = payload["prompt_id"] as? String ?? ""
            if nodeID == nil {
                return .executed(promptID: promptID)
            }
            return .executing(nodeID: nodeID, promptID: promptID)

        case "execution_error":
            let errorMsg = payload["exception_message"] as? String ?? "Unknown error"
            let promptID = payload["prompt_id"] as? String
            return .error(promptID: promptID, message: errorMsg)

        case "execution_interrupted":
            let promptID = payload["prompt_id"] as? String
            return .error(promptID: promptID, message: ComfyUIError.interruptedMessage)

        default:
            break
        }

        return nil
    }
}
