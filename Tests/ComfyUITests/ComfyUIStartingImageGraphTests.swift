import XCTest
@testable import ComfyUI

/// A starting image on ComfyUI: a text-to-image graph is rewritten to start from the uploaded
/// image (`ComfyUIStartingImageGraph`), and the upload is a multipart `POST /upload/image`.
final class ComfyUIStartingImageGraphTests: XCTestCase {

    /// A text-to-image graph shaped like the SDXL built-in: checkpoint "4" supplies the VAE
    /// (output 2), empty latent "5" feeds sampler "3", and "8" decodes.
    private func textToImageGraph(width: Int = 1024, height: Int = 1024, batchSize: Int = 1) -> [String: ComfyUINode] {
        [
            "4": ComfyUINode(classType: "CheckpointLoaderSimple", inputs: ["ckpt_name": "model.safetensors"]),
            "5": ComfyUINode(classType: "EmptyLatentImage", inputs: [
                "width": .int(width), "height": .int(height), "batch_size": .int(batchSize)
            ]),
            "3": ComfyUINode(classType: "KSampler", inputs: ["model": .array(["4", 0]), "latent_image": .array(["5", 0])]),
            "8": ComfyUINode(classType: "VAEDecode", inputs: ["samples": .array(["3", 0]), "vae": .array(["4", 2])])
        ]
    }

    func testRewriteLoadsAndEncodesTheImageInPlaceOfTheEmptyLatent() throws {
        let workflow = textToImageGraph(width: 832, height: 1216)
        let plan = try XCTUnwrap(ComfyUIStartingImageGraph.plan(for: workflow))
        XCTAssertEqual(plan.latentNodeID, "5")
        XCTAssertEqual(ComfyUIStartingImageGraph.size(of: workflow, plan: plan)?.width, 832)
        XCTAssertEqual(ComfyUIStartingImageGraph.size(of: workflow, plan: plan)?.height, 1216)

        let rewritten = ComfyUIStartingImageGraph.rewrite(workflow, plan: plan, image: "uploads/start.png")

        XCTAssertNil(rewritten["5"], "the empty latent is gone")
        let load = try XCTUnwrap(rewritten[ComfyUIStartingImageGraph.loadNodeID])
        XCTAssertEqual(load.classType, "LoadImage")
        XCTAssertEqual(load.inputs["image"], .string("uploads/start.png"))
        let encode = try XCTUnwrap(rewritten[ComfyUIStartingImageGraph.encodeNodeID])
        XCTAssertEqual(encode.classType, "VAEEncode")
        XCTAssertEqual(encode.inputs["vae"], .array([.string("4"), .int(2)]), "the VAE the graph decodes with")
        XCTAssertEqual(rewritten["3"]?.inputs["latent_image"], .array([.string(ComfyUIStartingImageGraph.encodeNodeID), .int(0)]))
        XCTAssertNil(rewritten[ComfyUIStartingImageGraph.repeatNodeID], "one image, no repeat")
    }

    func testABatchRepeatsTheEncodedImage() throws {
        let workflow = textToImageGraph(batchSize: 3)
        let plan = try XCTUnwrap(ComfyUIStartingImageGraph.plan(for: workflow))
        let rewritten = ComfyUIStartingImageGraph.rewrite(workflow, plan: plan, image: "start.png")

        let repeated = try XCTUnwrap(rewritten[ComfyUIStartingImageGraph.repeatNodeID])
        XCTAssertEqual(repeated.inputs["amount"], .int(3))
        XCTAssertEqual(rewritten["3"]?.inputs["latent_image"], .array([.string(ComfyUIStartingImageGraph.repeatNodeID), .int(0)]))
    }

    func testGraphsThatCannotTakeAnImageAreLeftAlone() {
        let decode = ComfyUINode(classType: "VAEDecode", inputs: ["samples": .array(["3", 0]), "vae": .array(["4", 2])])
        let latent = ComfyUINode(classType: "EmptyLatentImage", inputs: ["width": 512, "height": 512])
        XCTAssertNotNil(ComfyUIStartingImageGraph.plan(for: ["5": latent, "8": decode]))
        XCTAssertNil(ComfyUIStartingImageGraph.plan(for: ["5": latent]), "no VAE to encode with")
        XCTAssertNil(ComfyUIStartingImageGraph.plan(for: ["5": latent, "6": latent, "8": decode]), "two empty latents")
        XCTAssertNil(
            ComfyUIStartingImageGraph.plan(for: ["5": latent, "8": decode, "1": ComfyUINode(classType: "LoadImage", inputs: [:])]),
            "already loads an image"
        )
    }

    func testMultipartBodyCarriesTheImageAsAnInputFile() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let body = ComfyUIClient.multipartBody(png: png, filename: "start.png", boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--B\r\n"))
        XCTAssertTrue(text.contains(#"Content-Disposition: form-data; name="image"; filename="start.png""#))
        XCTAssertTrue(text.contains("Content-Type: image/png"))
        XCTAssertTrue(text.contains("name=\"type\"\r\n\r\ninput\r\n"))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
        XCTAssertNotNil(body.range(of: png))
    }
}
