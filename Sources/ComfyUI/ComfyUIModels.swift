import Foundation

// MARK: - Request types

struct ComfyUIPromptRequest: Encodable, Sendable {
    let prompt: [String: ComfyUINode]
    let clientID: String
    /// Per-prompt server options. `preview_method` asks the samplers for latent previews for
    /// this prompt regardless of the server's `--preview-method` launch flag, whose default is
    /// no previews: a server started without the flag sends no binary preview frames to any
    /// client that does not ask. "auto" is ComfyUI's cheap latent-to-RGB approximation; TAESD
    /// is a separate opt-in method (`latent_preview.get_previewer`, applied per prompt by
    /// `execution.py` → `set_preview_method`).
    var extraData: [String: String] = ["preview_method": "auto"]

    enum CodingKeys: String, CodingKey {
        case prompt
        case clientID = "client_id"
        case extraData = "extra_data"
    }
}

/// One node of an API-format workflow (`"3": {"class_type": "KSampler", "inputs": {...}}`).
/// A workflow is `[String: ComfyUINode]`, keyed by node ID, as in a file saved with
/// ComfyUI's "Export (API)".
public struct ComfyUINode: Codable, Sendable {
    /// The node's class, such as `KSampler` or `CheckpointLoaderSimple`.
    public let classType: String
    /// Input values by name. A link to another node's output is a two-element array,
    /// `[node ID, output index]`.
    public var inputs: [String: AnyCodableValue]

    /// A node of class `classType` with `inputs`.
    public init(classType: String, inputs: [String: AnyCodableValue]) {
        self.classType = classType
        self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey {
        case classType = "class_type"
        case inputs
    }
}

// MARK: - Response types

/// `POST /upload/image`: where the server stored the file.
struct ComfyUIUploadResponse: Decodable, Sendable {
    let name: String
    let subfolder: String
}

/// The server's reply to ``ComfyUIClient/queuePrompt(_:clientID:)``.
public struct ComfyUIPromptResponse: Decodable, Sendable {
    /// The ID the server gave the prompt; WebSocket events and the history use it.
    public let promptID: String
    /// The prompt's position number in the server's queue.
    public let number: Int

    enum CodingKeys: String, CodingKey {
        case promptID = "prompt_id"
        case number
    }
}

/// A finished prompt's outcome in `/history`; `status_str` is "success" or "error".
struct ComfyUIHistoryStatus: Decodable, Sendable {
    let statusStr: String?
    let completed: Bool?
    /// Event log as `[name, details]` pairs, e.g. `execution_error` or `execution_interrupted`.
    let messages: [[AnyCodableValue]]?

    enum CodingKeys: String, CodingKey {
        case statusStr = "status_str"
        case completed
        case messages
    }

    init(statusStr: String?, completed: Bool?, messages: [[AnyCodableValue]]? = nil) {
        self.statusStr = statusStr
        self.completed = completed
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusStr = try container.decodeIfPresent(String.self, forKey: .statusStr)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
        // The log is only used for the failure message, so a shape change must not break decoding.
        messages = try? container.decodeIfPresent([[AnyCodableValue]].self, forKey: .messages)
    }
}

/// What a history entry says about its prompt, from ``ComfyUIHistoryEntry/outcome``.
public enum ComfyUIHistoryOutcome: Equatable, Sendable {
    /// Not finished, or not reported yet; ask again later.
    case pending
    /// ComfyUI ended the prompt with an error or an interruption; the message says which.
    case failed(String)
    /// The prompt finished; its outputs are final.
    case succeeded
}

extension ComfyUIHistoryOutcome {
    /// Throws unless the prompt succeeded: ``ComfyUIError/historyIncomplete`` while pending (ask
    /// again later), ``ComfyUIError/executionFailed(_:)`` when it failed.
    public func requireSucceeded() throws {
        switch self {
        case .pending: throw ComfyUIError.historyIncomplete
        case .failed(let message): throw ComfyUIError.executionFailed(message)
        case .succeeded: break
        }
    }
}

extension ComfyUIHistoryEntry {
    /// Whether the prompt is pending, failed or succeeded. An entry without a status that has
    /// outputs is treated as finished (older servers); one with neither is pending.
    public var outcome: ComfyUIHistoryOutcome {
        guard let status else { return outputs.isEmpty ? .pending : .succeeded }
        if status.statusStr == "error" { return .failed(failureMessage) }
        if status.completed == false {
            // A terminal status other than success that never completed is a failure;
            // no status string means ComfyUI has not settled on an outcome yet.
            guard let statusStr = status.statusStr, statusStr != "success" else { return .pending }
            return .failed(failureMessage)
        }
        return .succeeded
    }

    private var failureMessage: String {
        for entry in status?.messages ?? [] {
            guard case .string(let name)? = entry.first else { continue }
            if name == "execution_interrupted" { return ComfyUIError.interruptedMessage }
            if name == "execution_error", entry.count > 1, case .dictionary(let details) = entry[1],
               case .string(let text)? = details["exception_message"], !text.isEmpty {
                return text
            }
        }
        return "ComfyUI reported an error while generating"
    }
}

/// One prompt in `/history`: its outputs by node, and its status once finished.
public struct ComfyUIHistoryEntry: Decodable, Sendable {
    /// What each output node produced, keyed by node ID.
    public let outputs: [String: NodeOutput]

    /// Present once the prompt has finished.
    let status: ComfyUIHistoryStatus?

    /// One node's outputs.
    public struct NodeOutput: Decodable, Sendable {
        /// The node's images, if it produced any.
        public let images: [OutputImage]?
    }

    /// An image on the server, downloadable with ``ComfyUIClient/downloadOutput(filename:subfolder:type:to:limit:)``.
    public struct OutputImage: Decodable, Sendable {
        /// The file name in the server's folder.
        public let filename: String
        /// The subfolder within it, or empty.
        public let subfolder: String
        /// `output` for saved images (`SaveImage`), `temp` for previews (`PreviewImage`).
        public let type: String
    }
}

struct ComfyUINodeInfo: Decodable, Sendable {
    let input: ComfyUINodeInputs

    struct ComfyUINodeInputs: Decodable, Sendable {
        let required: [String: [AnyCodableValue]]
    }
}

/// The `system` part of `/system_stats`.
public struct ComfyUISystemInfo: Decodable, Sendable {
    /// The server's operating system, as Python reports it (such as `posix` or `nt`).
    public let os: String
    /// The ComfyUI version, such as `0.3.60`; absent on older servers.
    public let comfyuiVersion: String?

    enum CodingKeys: String, CodingKey {
        case os
        case comfyuiVersion = "comfyui_version"
    }
}

/// The server's `/system_stats`, from ``ComfyUIClient/checkConnection()``.
public struct ComfyUISystemStats: Decodable, Sendable {
    /// The server and its version.
    public let system: ComfyUISystemInfo
}

// MARK: - WebSocket event types

/// An event from ``ComfyUIWebSocket/events()``.
public enum ComfyUIProgressEvent: Sendable {
    /// How many prompts are queued or running on the server.
    case queueRemaining(Int)
    /// A sampler step of a node. `promptID` is empty when the server does not say.
    case progress(promptID: String, node: String?, step: Int, total: Int)
    /// A latent preview image (JPEG or PNG data) of the running prompt.
    case preview(Data)
    /// A node of the prompt started executing.
    case executing(nodeID: String?, promptID: String)
    /// The prompt finished executing; its outputs are in the history.
    case executed(promptID: String)
    /// A prompt failed or was interrupted (then `message` is ``ComfyUIError/interruptedMessage``).
    case error(promptID: String?, message: String)
    /// The connection itself failed or closed, and the stream ends. Not a prompt error: ComfyUI
    /// may still be running the prompts, so check the history after reconnecting.
    case disconnected(reason: String)
    /// The handshake got a 3xx, which is not followed, and the stream ends; `location` is its target.
    case redirected(location: String?)
}

// MARK: - Flexible JSON value encoding

/// A JSON value: a node input, or anything else in ComfyUI's loosely typed replies. Literals
/// make inputs easy to write: `["seed": 42, "cfg": 7.5, "ckpt_name": "model.safetensors"]`.
public enum AnyCodableValue: Sendable, Equatable {
    /// A JSON string.
    case string(String)
    /// A JSON number without a fraction.
    case int(Int)
    /// A JSON number with a fraction.
    case double(Double)
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON array, such as a link `["4", 0]`.
    case array([Self])
    /// A JSON object.
    case dictionary([String: Self])
}

extension AnyCodableValue: Codable {
    /// Encodes the value as the matching JSON type.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        }
    }

    /// Decodes any JSON value except `null`, trying bool, int, double, string, array and object in turn.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([Self].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: Self].self) {
            self = .dictionary(v)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }
}

extension AnyCodableValue: ExpressibleByStringLiteral {
    /// A ``string(_:)`` value.
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AnyCodableValue: ExpressibleByIntegerLiteral {
    /// An ``int(_:)`` value.
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension AnyCodableValue: ExpressibleByFloatLiteral {
    /// A ``double(_:)`` value.
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension AnyCodableValue: ExpressibleByBooleanLiteral {
    /// A ``bool(_:)`` value.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
