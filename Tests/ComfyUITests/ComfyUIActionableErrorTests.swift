import XCTest
@testable import ComfyUI

/// Connection and submit errors the user can act on: failures are classified into
/// advice, and `/prompt` rejections list the failed nodes and inputs.
@MainActor
final class ComfyUIActionableErrorTests: XCTestCase {

    /// A trimmed real reply for a workflow whose checkpoint isn't installed and whose
    /// SaveImage lost its input.
    private static let rejectionBody = Data(#"""
    {"error": {"type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation",
               "details": "", "extra_info": {}},
     "node_errors": {
        "10": {"errors": [{"type": "required_input_missing", "message": "Required input is missing",
                           "details": "images", "extra_info": {"input_name": "images"}}],
               "dependent_outputs": ["10"], "class_type": "SaveImage"},
        "4": {"errors": [{"type": "value_not_in_list", "message": "Value not in list",
                          "details": "ckpt_name: 'missing.safetensors' not in ['sd15.safetensors']",
                          "extra_info": {"input_name": "ckpt_name", "input_config": [["sd15.safetensors"]],
                                         "received_value": "missing.safetensors"}}],
              "dependent_outputs": ["9"], "class_type": "CheckpointLoaderSimple"}
     }}
    """#.utf8)

    override func tearDownWithError() throws {
        StubURLProtocol.uninstall()
    }

    private func makeClient() throws -> ComfyUIClient {
        ComfyUIClient(endpoint: try ComfyUIEndpoint(host: "127.0.0.1", port: 1, useTLS: false))
    }

    // MARK: - Classification

    func testClassifiesRefusedTimeoutAndWrongServer() {
        XCTAssertEqual(ComfyUIConnectionFailure(URLError(.cannotConnectToHost)), .notRunning)
        XCTAssertEqual(ComfyUIConnectionFailure(URLError(.networkConnectionLost)), .notRunning)
        XCTAssertEqual(ComfyUIConnectionFailure(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(ComfyUIConnectionFailure(URLError(.cannotFindHost)), .hostNotFound)
        XCTAssertEqual(ComfyUIConnectionFailure(ComfyUIError.httpError(404)), .notComfyUI)
        XCTAssertEqual(ComfyUIConnectionFailure(ComfyUIError.responseTooLarge), .notComfyUI)
        XCTAssertEqual(ComfyUIConnectionFailure(ComfyUIError.httpError(503)), .other)
        XCTAssertEqual(ComfyUIConnectionFailure(ComfyUIError.redirected(to: nil)), .other)

        do {
            _ = try JSONDecoder().decode(ComfyUISystemStats.self, from: Data("<html></html>".utf8))
            XCTFail("expected a decoding error")
        } catch {
            XCTAssertEqual(ComfyUIConnectionFailure(error), .notComfyUI)
        }
    }

    func testRefusedAdviceMentionsListenOnlyForAnotherComputer() throws {
        let local = try XCTUnwrap(ComfyUIConnectionFailure.notRunning.advice(host: "localhost"))
        XCTAssertTrue(local.contains("Is ComfyUI running?"), local)
        XCTAssertFalse(local.contains("--listen"), local)

        let remote = try XCTUnwrap(ComfyUIConnectionFailure.notRunning.advice(host: "192.168.1.20"))
        XCTAssertTrue(remote.contains("Is ComfyUI running?"), remote)
        XCTAssertTrue(remote.contains("--listen"), remote)

        XCTAssertNil(ComfyUIConnectionFailure.other.advice(host: "localhost"))
    }

    // MARK: - /prompt rejections

    func testParsesNodeErrorsByNodeAndInput() throws {
        let rejection = try XCTUnwrap(ComfyUIPromptRejection(data: Self.rejectionBody))

        XCTAssertEqual(rejection.message, "Prompt outputs failed validation")
        XCTAssertNil(rejection.details)
        XCTAssertEqual(rejection.nodeFailures.map(\.nodeID), ["4", "10"], "sorted numerically")
        XCTAssertEqual(rejection.nodeFailures.first?.classType, "CheckpointLoaderSimple")
        XCTAssertEqual(rejection.nodeFailures.first?.issues, [
            .init(message: "Value not in list",
                  details: "ckpt_name: 'missing.safetensors' not in ['sd15.safetensors']",
                  inputName: "ckpt_name")
        ])
        XCTAssertEqual(rejection.lines, [
            "CheckpointLoaderSimple (node 4), ckpt_name: Value not in list: ckpt_name: 'missing.safetensors' not in ['sd15.safetensors']",
            "SaveImage (node 10), images: Required input is missing: images"
        ])
    }

    func testRejectionWithoutNodeErrorsShowsServerMessage() throws {
        let rejection = try XCTUnwrap(ComfyUIPromptRejection(data: Data(#"{"error": "no prompt", "node_errors": []}"#.utf8)))

        XCTAssertTrue(rejection.nodeFailures.isEmpty)
        XCTAssertEqual(rejection.description(statusCode: 400), "ComfyUI rejected the workflow: no prompt\n(HTTP 400: no prompt)")
    }

    func testNonComfyUIBodyIsNotARejection() {
        XCTAssertNil(ComfyUIPromptRejection(data: Data("<html>Bad Request</html>".utf8)))
        XCTAssertNil(ComfyUIPromptRejection(data: Data(#"{"detail": "nope"}"#.utf8)))
    }

    func testLongDetailsAreShortened() throws {
        let longList = String(repeating: "model.safetensors, ", count: 50)
        let body = #"{"error": {"message": "Prompt outputs failed validation"}, "node_errors": {"4": {"class_type": "CheckpointLoaderSimple", "errors": [{"message": "Value not in list", "details": "\#(longList)", "extra_info": {"input_name": "ckpt_name"}}]}}}"#
        let rejection = try XCTUnwrap(ComfyUIPromptRejection(data: Data(body.utf8)))

        let line = try XCTUnwrap(rejection.lines.first)
        XCTAssertTrue(line.hasSuffix("\u{2026}"), line)
        XCTAssertLessThan(line.count, longList.count)
    }

    func testQueuePromptRejectionListsFailedInputsAndKeepsStatus() async throws {
        let body = Self.rejectionBody
        StubURLProtocol.install { request in
            request.url?.path == "/prompt" ? (400, body) : (404, Data())
        }

        do {
            _ = try await makeClient().queuePrompt([:], clientID: "c")
            XCTFail("expected the rejection to throw")
        } catch ComfyUIError.promptRejected(let statusCode, let rejection) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(rejection.nodeFailures.count, 2)
            let text = ComfyUIError.promptRejected(statusCode: statusCode, rejection).localizedDescription
            XCTAssertTrue(text.contains("CheckpointLoaderSimple (node 4), ckpt_name: Value not in list"), text)
            XCTAssertTrue(text.contains("SaveImage (node 10), images"), text)
            XCTAssertTrue(text.contains("(HTTP 400: Prompt outputs failed validation)"), text)
            XCTAssertFalse(text.contains("ComfyUI returned HTTP 400"), text)
        }
    }

    func testQueuePromptErrorWithoutComfyUIBodyStillReportsStatus() async throws {
        StubURLProtocol.install { _ in (500, Data("Internal Server Error".utf8)) }

        do {
            _ = try await makeClient().queuePrompt([:], clientID: "c")
            XCTFail("expected the error status to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ComfyUI returned HTTP 500")
        }
    }
}
