import Foundation
import XCTest
@testable import ComfyUI

/// Response bodies and queued WebSocket events are bounded regardless of what the
/// server declares or how fast it sends.
final class ComfyUIResourceLimitTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComfyUIResourceLimitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.uninstall()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Bounded responses

    func testBodyWithoutContentLengthIsCutOffAtTheLimit() async throws {
        // The stub declares no Content-Length, like a chunked response.
        StubURLProtocol.install { _ in (200, Data(repeating: 0x20, count: 64 * 1024)) }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:1/object_info/KSampler")!)

        do {
            _ = try await BoundedResponse.data(for: request, limit: 1024)
            XCTFail("an oversized body must be rejected")
        } catch is BoundedResponse.TooLarge {}

        let (data, _) = try await BoundedResponse.data(for: request, limit: 64 * 1024)
        XCTAssertEqual(data.count, 64 * 1024)
    }

    func testOversizedDownloadLeavesNoFile() async throws {
        StubURLProtocol.install { _ in (200, Data(repeating: 0x20, count: 64 * 1024)) }
        let destination = tempDir.appendingPathComponent("out")

        do {
            _ = try await BoundedResponse.download(
                for: URLRequest(url: URL(string: "http://127.0.0.1:1/view")!), limit: 1024, to: destination
            )
            XCTFail("an oversized body must be rejected")
        } catch is BoundedResponse.TooLarge {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testClientMapsOversizedJSONToResponseTooLarge() async throws {
        let oversized = Data(repeating: 0x20, count: ComfyUIClient.maxSmallResponseSize + 1)
        StubURLProtocol.install { _ in (200, oversized) }
        let client = ComfyUIClient(endpoint: try ComfyUIEndpoint(host: "127.0.0.1", port: 1, useTLS: false))

        do {
            _ = try await client.checkConnection()
            XCTFail("an oversized status reply must be rejected")
        } catch ComfyUIError.responseTooLarge {}
    }

    func testCancelRequestsAreBoundedToo() async throws {
        let oversized = Data(repeating: 0x20, count: 2 * 1024 * 1024)
        StubURLProtocol.install { _ in (200, oversized) }
        let client = ComfyUIClient(endpoint: try ComfyUIEndpoint(host: "127.0.0.1", port: 1, useTLS: false))

        do {
            try await client.interrupt(promptID: "p")
            XCTFail("an oversized interrupt reply must be rejected")
        } catch ComfyUIError.responseTooLarge {}
        do {
            try await client.deleteQueueItem(promptID: "p")
            XCTFail("an oversized queue reply must be rejected")
        } catch ComfyUIError.responseTooLarge {}
    }

    // MARK: - WebSocket event channel

    func testPreviewFloodKeepsOnlyTheNewestPreview() async {
        let channel = ComfyUIEventChannel()
        for index in 0..<1000 {
            await channel.send(.preview(Data([UInt8(index % 256)])))
        }
        await channel.send(.executed(promptID: "p"))
        await channel.finish()

        let events = await drain(channel)
        XCTAssertEqual(events.count, 2)
        guard case .preview(let data) = events.first else { return XCTFail("expected a preview first") }
        XCTAssertEqual(data, Data([UInt8(999 % 256)]))
        guard case .executed("p") = events.last else { return XCTFail("the terminal event must survive") }
    }

    func testProgressUpdatesCoalesceAndTerminalEventsKeepTheirOrder() async {
        let channel = ComfyUIEventChannel()
        for step in 1...500 {
            await channel.send(.progress(promptID: "p", node: "3", step: step, total: 500))
        }
        await channel.send(.error(promptID: "p", message: "boom"))
        await channel.send(.disconnected(reason: "closed"))
        await channel.finish()

        let events = await drain(channel)
        XCTAssertEqual(events.count, 3)
        guard case .progress(_, _, 500, 500) = events[0] else { return XCTFail("latest progress expected") }
        guard case .error("p", "boom") = events[1], case .disconnected = events[2] else { return XCTFail("order lost") }
    }

    func testRoutineEventsAreCappedButTerminalEventsStillArrive() async {
        let channel = ComfyUIEventChannel()
        for index in 0..<(ComfyUIEventChannel.maxQueuedEvents * 4) {
            await channel.send(.executing(nodeID: "\(index)", promptID: "p"))
        }
        await channel.send(.executed(promptID: "p"))
        await channel.finish()

        let events = await drain(channel)
        XCTAssertEqual(events.count, ComfyUIEventChannel.maxQueuedEvents + 1)
        guard case .executed = events.last else { return XCTFail("terminal event dropped") }
    }

    func testTerminalOverflowClosesTheChannelWithADisconnect() async {
        // Dropping a completion silently could strand its job on a live connection. Overflow
        // instead ends the connection, whose loss triggers reconnect and reconciliation.
        let channel = ComfyUIEventChannel()
        for index in 0..<ComfyUIEventChannel.maxTotalEvents {
            await channel.send(.executed(promptID: "flood-\(index)"))
        }
        await channel.send(.executed(promptID: "real-job"))
        let closed = await channel.isClosed
        XCTAssertTrue(closed)
        await channel.send(.executed(promptID: "after-close"))

        let events = await drain(channel)
        XCTAssertEqual(events.count, ComfyUIEventChannel.maxTotalEvents + 1)
        guard case .disconnected(ComfyUIEventChannel.overflowReason) = events.last else {
            return XCTFail("overflow must end with a disconnect")
        }
    }

    func testWaitingConsumerReceivesEventsAsTheyArrive() async {
        let channel = ComfyUIEventChannel()
        async let first = channel.next()
        try? await Task.sleep(for: .milliseconds(20))
        await channel.send(.queueRemaining(2))
        guard case .queueRemaining(2)? = await first else { return XCTFail("expected the queued event") }

        await channel.finish()
        let afterFinish = await channel.next()
        XCTAssertNil(afterFinish)
    }

    private func drain(_ channel: ComfyUIEventChannel) async -> [ComfyUIProgressEvent] {
        var events: [ComfyUIProgressEvent] = []
        while let event = await channel.next() {
            events.append(event)
        }
        return events
    }
}
