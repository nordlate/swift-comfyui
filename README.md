# swift-comfyui

An async/await Swift client for a [ComfyUI](https://github.com/comfyanonymous/ComfyUI) server, on macOS and iOS.

`ComfyUI` queues prompts, follows their progress over the WebSocket, uploads images and downloads outputs. Every response is read with a
size limit, every request of a connection runs under a grant that ends them all at once, and a prompt the server refuses comes back as an
error that names the failing node and input, not just an HTTP 400. It uses only Apple's system frameworks (Foundation and os) and has
no dependencies.

> **Unofficial.** This project is not affiliated with, endorsed by or maintained by Comfy Org or the ComfyUI project.

## What it covers

| Call | Server API |
|---|---|
| `ComfyUIClient.checkConnection()` | `GET /system_stats`: the server answers, and its version |
| `queuePrompt(_:clientID:)` | `POST /prompt` with an API-format workflow; asks for latent previews per prompt |
| `ComfyUIWebSocket.events()` | `/ws`: queue size, step progress, previews, node and prompt completion, errors |
| `getHistory(promptID:)`, `ComfyUIHistoryEntry.outcome` | `GET /history/{id}`: whether a prompt succeeded, failed or is still pending, and its output files |
| `downloadOutput(filename:subfolder:type:to:limit:)` | `GET /view`, streamed to a file |
| `uploadImage(_:filename:)` | `POST /upload/image` into the input folder |
| `queuedPromptIDs()`, `interrupt(promptID:)`, `deleteQueueItem(promptID:)` | `GET /queue`, `POST /interrupt` (targeted), `POST /queue` delete |
| `getInputOptions(for:inputName:)` | `GET /object_info/{class}`: installed checkpoints, samplers, schedulers and other choices |
| `ComfyUIStartingImageGraph` | rewrites a text-to-image workflow to start from an uploaded image |

Limits: status and queue replies 1 MiB, history and node info 32 MiB, each output file 200 MiB (or less, per call), each WebSocket message
10 MiB, uploads 64 MiB. A declared `Content-Length` only rejects an oversized body early; a body without one is cut off at the limit. Events
the consumer has not read yet are queued with a bound too: progress updates coalesce and only the newest preview is kept.

## Requirements

- macOS 15 or iOS 18 or later
- Swift 6.0 or later (Xcode 16 or later); the package builds in Swift 6 language mode

## Installation

Add the package with Swift Package Manager and depend on the `ComfyUI` product:

```swift
.package(url: "https://github.com/nordlate/swift-comfyui", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ComfyUI", package: "swift-comfyui"),
])
```

## Usage

```swift
import ComfyUI
import Foundation

let endpoint = try ComfyUIEndpoint(host: "127.0.0.1", port: 8188, useTLS: false)
let client = ComfyUIClient(endpoint: endpoint)
let stats = try await client.checkConnection()
print("ComfyUI", stats.system.comfyuiVersion ?? "unknown")

// Open the WebSocket before queueing, with the same client ID, so no event is missed.
let clientID = UUID().uuidString
let events = ComfyUIWebSocket(endpoint: endpoint, clientID: clientID).events()

// A workflow saved with "Export (API)" in ComfyUI.
let json = try Data(contentsOf: URL(fileURLWithPath: "workflow_api.json"))
var workflow = try JSONDecoder().decode([String: ComfyUINode].self, from: json)
workflow["6"]?.inputs["text"] = "a lighthouse at dusk"
let prompt = try await client.queuePrompt(workflow, clientID: clientID)

events: for await event in events {
    switch event {
    case .progress(prompt.promptID, _, let step, let total):
        print("step \(step) of \(total)")
    case .executed(prompt.promptID):
        break events
    case .error(prompt.promptID, let message):
        throw ComfyUIError.executionFailed(message)
    case .disconnected, .redirected:
        break events  // ComfyUI may still finish it: check the history after reconnecting
    default:
        break
    }
}

let entry = try await client.getHistory(promptID: prompt.promptID)
try entry.outcome.requireSucceeded()
for image in entry.outputs.values.flatMap({ $0.images ?? [] }) where image.type == "output" {
    let file = URL(fileURLWithPath: image.filename)
    _ = try await client.downloadOutput(filename: image.filename, subfolder: image.subfolder, type: image.type, to: file)
}
```

A workflow the server refuses throws `ComfyUIError.promptRejected`, whose message reads like
`CheckpointLoaderSimple (node 4), ckpt_name: Value not in list: …`; `ComfyUIPromptRejection.nodeFailures` has the same per node and input.
`ComfyUIConnectionFailure(error).advice(host:)` turns a failed `checkConnection()` into advice such as "Is ComfyUI running?".

### Connection grants

Every request of a client runs under its `ComfyUIConnectionGrant`. Give all clients of one connection the same grant and call `revoke()`
when the user disconnects or changes the server settings: running requests and downloads are cancelled, later ones fail with
`ComfyUIError.connectionRevoked`, including those of client copies a task still holds across an `await`. A client made without a grant
gets one of its own.

```swift
let grant = ComfyUIConnectionGrant()
let client = ComfyUIClient(endpoint: endpoint, grant: grant)
// ...
grant.revoke()
```

### Transport and plaintext on macOS

`ComfyUIEndpoint` accepts only a host name or IP address (no scheme, path or port) and picks HTTP/WS or HTTPS/WSS from `useTLS`. A server on
this computer may always use plain HTTP. For another host, turning TLS off is taken as the user's consent to unencrypted traffic; a TLS
failure is reported, never retried without TLS. Redirects are never followed, for HTTP requests or the WebSocket handshake, so a server
cannot move a connection to another host or from HTTPS to HTTP.

On macOS, App Transport Security only lets an app without ATS exceptions reach private and link-local addresses, `.local` names and
single-word host names over plain HTTP, so `ComfyUIEndpoint` refuses plaintext to any other host up front with
`Failure.plaintextBlockedByMacOS` rather than failing later. On iOS the app's own ATS settings decide.

## Versioning

Package releases follow semantic versioning, with a release tag per version; changes are listed in `CHANGELOG.md`. Before 1.0.0 a minor
version may change the public API.

## Tests

```bash
swift test
```

The tests answer HTTP requests with a `URLProtocol` stub, and use a TCP listener on 127.0.0.1 for redirects; no ComfyUI server is needed.

## Contributing

Maintained for the needs of the app that uses it; contributions are welcome. See `CONTRIBUTING.md`.

## Licence

MIT, see `LICENSE`.
