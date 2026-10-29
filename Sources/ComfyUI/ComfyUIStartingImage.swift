import Foundation

/// Rewrites a text-to-image graph to start from an image, so one workflow serves both modes and
/// no image-to-image copies need maintaining.
///
/// A text-to-image graph starts its sampler from an empty latent (`EmptyLatentImage`,
/// `EmptySD3LatentImage`, …). With a starting image that node is replaced by the uploaded image,
/// encoded with the VAE the graph already decodes with:
///
///     LoadImage(uploaded) → VAEEncode(vae) [→ RepeatLatentBatch(batch size)] → sampler
///
/// The sampler's `denoise` then decides how much of the image may change, as in ComfyUI's own
/// image-to-image example. A graph without exactly one empty latent, without a `VAEDecode` to take
/// the VAE from, or that already loads an image is left alone: it cannot take a starting image.
///
/// ```swift
/// if let plan = ComfyUIStartingImageGraph.plan(for: workflow),
///    let size = ComfyUIStartingImageGraph.size(of: workflow, plan: plan) {
///     let name = try await client.uploadImage(pngAt(size), filename: "start.png")
///     workflow = ComfyUIStartingImageGraph.rewrite(workflow, plan: plan, image: name)
/// }
/// ```
public enum ComfyUIStartingImageGraph {
    /// Where a graph takes a starting image, from ``plan(for:)``.
    public struct Plan: Equatable, Sendable {
        /// The empty latent node the image replaces.
        public let latentNodeID: String
        /// The VAE output the graph decodes with, as a link (`[node, output]`).
        let vae: AnyCodableValue
    }

    /// ID of the inserted `LoadImage` node. ComfyUI accepts any string ID, and these cannot clash
    /// with the numeric IDs of an API-format workflow.
    public static let loadNodeID = "start_image_load"
    /// ID of the inserted `VAEEncode` node.
    public static let encodeNodeID = "start_image_encode"
    /// ID of the `RepeatLatentBatch` node inserted for a batch size above 1.
    public static let repeatNodeID = "start_image_repeat"

    /// How `workflow` can take a starting image, or nil when it cannot.
    public static func plan(for workflow: [String: ComfyUINode]) -> Plan? {
        guard !workflow.values.contains(where: { $0.classType == "LoadImage" }) else { return nil }
        let latents = workflow.filter { Self.isEmptyLatent($0.value) }
        guard latents.count == 1, let latent = latents.first,
              let vae = workflow.values.first(where: { $0.classType == "VAEDecode" })?.inputs["vae"],
              case .array(let link) = vae, link.count == 2 else { return nil }
        return Plan(latentNodeID: latent.key, vae: vae)
    }

    /// The pixel size the graph generates at (its empty latent's `width` and `height`): the size
    /// to prepare the starting image at, so it is not stretched. Nil when they are not set as numbers.
    public static func size(of workflow: [String: ComfyUINode], plan: Plan) -> (width: Int, height: Int)? {
        guard let inputs = workflow[plan.latentNodeID]?.inputs,
              case .int(let width) = inputs["width"], case .int(let height) = inputs["height"],
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// The graph with the empty latent replaced by `image`, a file in ComfyUI's input folder (the
    /// name ``ComfyUIClient/uploadImage(_:filename:)`` returns). A batch size above 1 repeats
    /// the encoded image, and each copy is noised by its own seed.
    public static func rewrite(_ workflow: [String: ComfyUINode], plan: Plan, image: String) -> [String: ComfyUINode] {
        var result = workflow
        let batchSize: Int
        if case .int(let size) = workflow[plan.latentNodeID]?.inputs["batch_size"] { batchSize = size } else { batchSize = 1 }
        result[plan.latentNodeID] = nil

        result[loadNodeID] = ComfyUINode(classType: "LoadImage", inputs: ["image": .string(image)])
        result[encodeNodeID] = ComfyUINode(classType: "VAEEncode", inputs: [
            "pixels": .array([.string(loadNodeID), .int(0)]),
            "vae": plan.vae
        ])
        var latentSource = encodeNodeID
        // One image encodes to one latent; a batch repeats it, and each copy is noised by its own seed.
        if batchSize > 1 {
            result[repeatNodeID] = ComfyUINode(classType: "RepeatLatentBatch", inputs: [
                "samples": .array([.string(encodeNodeID), .int(0)]),
                "amount": .int(batchSize)
            ])
            latentSource = repeatNodeID
        }

        let replacement = AnyCodableValue.array([.string(latentSource), .int(0)])
        for (id, node) in result {
            for (name, value) in node.inputs where isLink(value, to: plan.latentNodeID) {
                result[id]?.inputs[name] = replacement
            }
        }
        return result
    }

    private static func isEmptyLatent(_ node: ComfyUINode) -> Bool {
        node.classType.hasPrefix("Empty") && node.classType.hasSuffix("LatentImage")
    }

    private static func isLink(_ value: AnyCodableValue, to nodeID: String) -> Bool {
        guard case .array(let link) = value, link.count == 2, case .string(let target) = link[0] else { return false }
        return target == nodeID
    }
}
