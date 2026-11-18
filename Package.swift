// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RayNeoCinema",
    platforms: [.macOS(.v13)],
    targets: [        // Core library: HID device layer + IMU fusion + (later) format
        // detection and render modes. The GUI app target will import this.
        .target(name: "RayNeoCore", path: "Sources/RayNeoCore"),
        // M1 verification CLI: run against the real glasses to prove
        // detection, panel commands and head tracking before the player
        // is built on top.
        .executableTarget(
            name: "rayneo-cli",
            dependencies: ["RayNeoCore"],
            path: "Sources/rayneo-cli"
        ),
        // The player app (M2+): AVPlayer + Metal per-eye VR renderer +
        // session controller. Built into a real .app bundle by build.sh.
        .executableTarget(
            name: "RayNeoCinema",
            dependencies: ["RayNeoCore"],
            path: "Sources/RayNeoCinema"
        ),
        // Standalone decode probe: run against any file to see whether
        // AVAsset/AVPlayer/AVPlayerItemVideoOutput deliver frames.
        .executableTarget(
            name: "decode-test",
            path: "Sources/decode-test"
        ),
    ]
)
