// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fala",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FalaKit", targets: ["FalaKit"]),
        .executable(name: "Fala", targets: ["Fala"]),
        .executable(name: "FalaSpike", targets: ["FalaSpike"]),
    ],
    dependencies: [
        // Pinned on purpose (bus-factor mitigation, NFR-6). Bump only with a
        // deliberate re-validation of the ASR API surface (see CLAUDE.md).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")
    ],
    targets: [
        .target(
            name: "FalaKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            // SwiftPM requires bundled resources to live inside the target
            // directory, so the default jargon dictionary lives here rather than
            // at the repo root. Users override it with their own copy at runtime.
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Fala",
            dependencies: ["FalaKit"]
        ),
        // Spike 0 WER harness — throwaway, delete after the engine decision (TASKS.md).
        .executableTarget(
            name: "FalaSpike",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .testTarget(
            name: "FalaKitTests",
            dependencies: ["FalaKit"]
        ),
    ]
)
