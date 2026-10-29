import Foundation

/// ComfyUI's reply when `/prompt` refuses a workflow, such as a checkpoint that isn't
/// installed: `{"error": {...}, "node_errors": {"4": {"class_type": ..., "errors": [...]}}}`.
/// Older servers send `error` as a string and `node_errors` as an empty array, so the body is
/// read leniently. Carried by ``ComfyUIError/promptRejected(statusCode:_:)``, whose
/// `localizedDescription` lists one line per failed input.
public struct ComfyUIPromptRejection: Equatable, Sendable {
    /// One reason a node failed validation.
    public struct Issue: Equatable, Sendable {
        /// ComfyUI's message, such as "Value not in list".
        public let message: String
        /// More detail, such as the rejected value and the allowed ones.
        public let details: String?
        /// The node input that failed, from `extra_info.input_name`.
        public let inputName: String?
    }

    /// A node that failed validation and why.
    public struct NodeFailure: Equatable, Sendable {
        /// The node's ID in the submitted workflow.
        public let nodeID: String
        /// The node's class, such as `CheckpointLoaderSimple`.
        public let classType: String?
        /// The node's failures, one per input where the server names it.
        public let issues: [Issue]
    }

    /// `error.message` (or the string `error`), e.g. "Prompt outputs failed validation".
    public let message: String?
    /// `error.details`, when given.
    public let details: String?
    /// Sorted by node ID, numerically where the IDs are numbers.
    public let nodeFailures: [NodeFailure]

    /// Longer details (a "not in list" one lists every installed model) are cut to this.
    static let maxDetailLength = 200

    /// Nil when `data` isn't a ComfyUI error reply.
    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] != nil || root["node_errors"] != nil else { return nil }

        switch root["error"] {
        case let error as [String: Any]:
            message = Self.text(error["message"])
            details = Self.text(error["details"])
        case let error as String:
            message = Self.text(error)
            details = nil
        default:
            message = nil
            details = nil
        }

        let nodes = root["node_errors"] as? [String: Any] ?? [:]
        nodeFailures = nodes.compactMap { nodeID, value -> NodeFailure? in
            guard let node = value as? [String: Any] else { return nil }
            let issues = (node["errors"] as? [[String: Any]] ?? []).map { issue in
                Issue(
                    message: Self.text(issue["message"]) ?? "Invalid input",
                    details: Self.text(issue["details"]),
                    inputName: Self.text((issue["extra_info"] as? [String: Any])?["input_name"])
                )
            }
            return NodeFailure(nodeID: nodeID, classType: Self.text(node["class_type"]), issues: issues)
        }
        .sorted { lhs, rhs in
            if let left = Int(lhs.nodeID), let right = Int(rhs.nodeID) { return left < right }
            return lhs.nodeID < rhs.nodeID
        }
    }

    /// One line per failed input, such as
    /// "CheckpointLoaderSimple (node 4), ckpt_name: Value not in list: …". Long details are shortened.
    public var lines: [String] {
        nodeFailures.flatMap { node -> [String] in
            let nodeLabel = node.classType.map { "\($0) (node \(node.nodeID))" } ?? "Node \(node.nodeID)"
            guard !node.issues.isEmpty else { return ["\(nodeLabel): failed validation"] }
            return node.issues.map { issue in
                let target = issue.inputName.map { "\(nodeLabel), \($0)" } ?? nodeLabel
                let details = issue.details.map { ": \(Self.truncated($0))" } ?? ""
                return "\(target): \(issue.message)\(details)"
            }
        }
    }

    /// The readable report, ending with the raw status and ComfyUI's own message.
    func description(statusCode: Int) -> String {
        var text: [String]
        let failures = lines
        if failures.isEmpty {
            let reason = [message, details.map(Self.truncated)].compactMap { $0 }.joined(separator: ": ")
            text = [reason.isEmpty ? "ComfyUI rejected the workflow." : "ComfyUI rejected the workflow: \(reason)"]
        } else {
            text = ["ComfyUI rejected the workflow:"] + failures.map { "\u{2022} \($0)" }
        }
        text.append("(HTTP \(statusCode)\(message.map { ": \($0)" } ?? ""))")
        return text.joined(separator: "\n")
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncated(_ text: String) -> String {
        text.count > maxDetailLength ? String(text.prefix(maxDetailLength)) + "\u{2026}" : text
    }
}
