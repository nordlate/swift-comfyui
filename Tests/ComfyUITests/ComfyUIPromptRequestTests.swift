import XCTest
@testable import ComfyUI

final class ComfyUIPromptRequestTests: XCTestCase {

    /// The prompt body must ask the server for previews itself: ComfyUI's default preview
    /// method is "none", so without `extra_data.preview_method` a server launched without
    /// `--preview-method` never sends binary preview frames.
    func testPromptBodyRequestsPreviewsPerPrompt() throws {
        let request = ComfyUIPromptRequest(
            prompt: ["6": ComfyUINode(classType: "CLIPTextEncode", inputs: ["text": .string("a cat")])],
            clientID: "client-1"
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["client_id"] as? String, "client-1")
        XCTAssertNotNil(json["prompt"])
        let extra = try XCTUnwrap(json["extra_data"] as? [String: Any])
        XCTAssertEqual(extra["preview_method"] as? String, "auto")
    }
}
