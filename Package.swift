// swift-tools-version: 6.0
// ComfyUI: an async/await client for a ComfyUI server.
import PackageDescription

let package = Package(
    name: "swift-comfyui",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ComfyUI", targets: ["ComfyUI"]),
    ],
    targets: [
        .target(name: "ComfyUI"),
        .testTarget(name: "ComfyUITests", dependencies: ["ComfyUI"]),
    ],
    swiftLanguageModes: [.v6]
)
