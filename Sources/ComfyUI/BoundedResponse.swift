import Foundation

/// Reads HTTP response bodies without trusting the server about their size.
///
/// `URLSession.data(for:)` buffers a whole body, however large, before returning. These
/// helpers stream it instead and stop as soon as more than `limit` bytes arrive. A declared
/// `Content-Length` only rejects an oversized body early; it is never trusted for allocation,
/// and a chunked body without one is bounded the same way.
enum BoundedResponse {

    struct TooLarge: Error {}

    /// The response body in memory. `validate` sees the response before any of the body is read.
    /// `delegate` receives this task's events, such as redirects.
    static func data(
        for request: URLRequest,
        session: URLSession = .shared,
        delegate: URLSessionTaskDelegate? = nil,
        limit: Int,
        validate: (URLResponse) throws -> Void = { _ in }
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try validate(response)
        try checkDeclaredLength(of: response, limit: limit)

        var collected = Data()
        try await read(bytes, limit: limit) { collected.append($0) }
        return (collected, response)
    }

    /// Streams the response body to a new file at `destination` and returns its size. The file
    /// is removed if the body is too large, the transfer fails or the task is cancelled.
    static func download(
        for request: URLRequest,
        session: URLSession = .shared,
        delegate: URLSessionTaskDelegate? = nil,
        limit: Int,
        to destination: URL,
        validate: (URLResponse) throws -> Void = { _ in }
    ) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        try validate(response)
        try checkDeclaredLength(of: response, limit: limit)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            return try await read(bytes, limit: limit) { try handle.write(contentsOf: $0) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static let chunkSize = 256 * 1024

    private static func checkDeclaredLength(of response: URLResponse, limit: Int) throws {
        // `expectedContentLength` is -1 when the server declares none.
        if response.expectedContentLength > Int64(limit) { throw TooLarge() }
    }

    @discardableResult
    private static func read(
        _ bytes: URLSession.AsyncBytes,
        limit: Int,
        into sink: (Data) throws -> Void
    ) async throws -> Int {
        var total = 0
        var chunk = Data()
        chunk.reserveCapacity(min(chunkSize, limit))
        for try await byte in bytes {
            total += 1
            if total > limit { throw TooLarge() }
            chunk.append(byte)
            if chunk.count == chunkSize {
                try Task.checkCancellation()
                try sink(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { try sink(chunk) }
        return total
    }
}
