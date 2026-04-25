// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure Swift models — no dependencies, fully testable
        .target(
            name: "OpenScribeModels",
            path: "Sources/OpenScribeModels"
        ),
        // Audio + ViewModel — AVFoundation + Combine
        .target(
            name: "OpenScribeCore",
            dependencies: ["OpenScribeModels"],
            path: "Sources/OpenScribeCore"
        ),
        // SwiftUI views
        .target(
            name: "OpenScribeUI",
            dependencies: ["OpenScribeCore"],
            path: "Sources/OpenScribeUI"
        ),
        // Entry point only
        .executableTarget(
            name: "OpenScribe",
            dependencies: ["OpenScribeCore", "OpenScribeUI"],
            path: "Sources/TranscribeApp"
        ),
        // Test target: pure Swift models only — AVFoundation is not loaded
        .testTarget(
            name: "TranscribeAppTests",
            dependencies: ["OpenScribeModels"],
            path: "Tests/TranscribeAppTests"
        ),
    ]
)
