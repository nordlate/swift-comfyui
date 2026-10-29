import Foundation
import os

extension Logger {
    /// The client's log.
    static let comfyUIClient = Logger(subsystem: "com.nordlate.ComfyUI", category: "ComfyUI")
}
