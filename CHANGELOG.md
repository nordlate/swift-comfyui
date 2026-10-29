# Changelog

The package uses semantic versioning. Before 1.0.0, a minor version may change the public API.

## 0.1.0

First release.

- `ComfyUIClient`: system status, queueing API-format workflows (with per-prompt latent previews), image upload, history, queue, targeted
  interrupt, queue deletion, node input options, and output downloads streamed to a file. Every response body is size-limited and redirects
  are refused.
- `ComfyUIWebSocket.events()`: queue, progress, preview, completion and error events through a bounded queue that coalesces progress and
  keeps only the newest preview.
- `ComfyUIEndpoint`: host validation, loopback detection, TLS or plaintext by choice, and the macOS App Transport Security rule for
  plaintext checked up front.
- `ComfyUIConnectionGrant`: revoking it cancels a connection's running requests and refuses new ones, across client copies.
- `ComfyUIPromptRejection` (in `ComfyUIError.promptRejected`) names each failed node and input; `ComfyUIConnectionFailure` turns a failed
  connection check into advice.
- `ComfyUIHistoryEntry.outcome` tells succeeded, failed (with ComfyUI's message) and pending prompts apart.
- `ComfyUIStartingImageGraph` rewrites a text-to-image workflow to start from an uploaded image.
