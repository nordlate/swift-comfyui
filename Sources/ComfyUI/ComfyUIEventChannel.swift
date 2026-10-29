import Foundation
import os

/// Ordered, bounded hand-off from the WebSocket receive loop to the event consumer.
///
/// The per-message size limit bounds each message, not how many pile up while the consumer
/// is busy, so a fast or hostile server could queue previews without end. Here:
/// - At most one preview waits at a time; a newer one replaces its image in place.
/// - A progress update replaces a queued one for the same prompt and node, and a queue-count
///   update replaces a queued queue-count update.
/// - Other routine events are dropped once `maxQueuedEvents` are waiting. Events that end a
///   job or the connection are still queued, up to the hard cap `maxTotalEvents`.
/// - Reaching the hard cap does not lose such an event silently: the channel closes after a
///   final `.disconnected`, the receive loop closes the socket, and the consumer's normal
///   connection-lost path reconnects and reconciles active jobs with ComfyUI's history.
actor ComfyUIEventChannel {
    static let maxQueuedEvents = 256
    static let maxTotalEvents = 1024

    private enum Entry {
        case event(ComfyUIProgressEvent)
        /// The newest preview, held in `latestPreview`.
        case preview
    }

    private var queue: [Entry] = []
    private var latestPreview: Data?
    private var finished = false
    private var waiter: CheckedContinuation<ComfyUIProgressEvent?, Never>?
    private var droppedCount = 0

    func send(_ event: ComfyUIProgressEvent) {
        guard !finished else { return }
        switch event {
        case .preview(let data):
            let alreadyQueued = latestPreview != nil
            latestPreview = data
            if !alreadyQueued { enqueue(.preview) }
        case .progress(let promptID, let node, _, _):
            if case .event(.progress(promptID, node, _, _))? = queue.last {
                queue[queue.count - 1] = .event(event)
            } else {
                enqueueRoutine(event)
            }
        case .queueRemaining:
            if case .event(.queueRemaining)? = queue.last {
                queue[queue.count - 1] = .event(event)
            } else {
                enqueueRoutine(event)
            }
        case .executing:
            enqueueRoutine(event)
        case .executed, .error, .disconnected, .redirected:
            guard queue.count < Self.maxTotalEvents else { return overflow() }
            enqueue(.event(event))
        }
    }

    /// Whether the channel accepts no more events (finished, or closed by overflow).
    var isClosed: Bool { finished }

    /// The next event, or nil once the channel is finished and drained.
    func next() async -> ComfyUIProgressEvent? {
        if !queue.isEmpty { return resolve(queue.removeFirst()) }
        if finished { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
        if droppedCount > 0 {
            Logger.comfyUIClient.warning("Dropped \(self.droppedCount) WebSocket events while the queue was full")
        }
    }

    private func enqueueRoutine(_ event: ComfyUIProgressEvent) {
        guard queue.count < Self.maxQueuedEvents else { return drop() }
        enqueue(.event(event))
    }

    private func enqueue(_ entry: Entry) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: resolve(entry))
        } else {
            queue.append(entry)
        }
    }

    private func resolve(_ entry: Entry) -> ComfyUIProgressEvent {
        switch entry {
        case .event(let event):
            return event
        case .preview:
            defer { latestPreview = nil }
            return .preview(latestPreview ?? Data())
        }
    }

    private func drop() {
        droppedCount += 1
    }

    /// A job-ending event would not fit. Queue one final `.disconnected` past the cap (the
    /// consumer is not waiting, since the queue is full) and close the channel.
    private func overflow() {
        drop()
        Logger.comfyUIClient.error("WebSocket event queue overflowed; closing the connection to recover")
        queue.append(.event(.disconnected(reason: Self.overflowReason)))
        finish()
    }

    /// The reason of the final `.disconnected` an overflow queues.
    static let overflowReason = "ComfyUI sent more events than the app could queue"
}
