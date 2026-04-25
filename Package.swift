// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [.macOS(.v13)],
    targets: [
        // Saf Swift modeller — bağımlılık yok, test edilebilir
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
        // Sadece giriş noktası
        .executableTarget(
            name: "OpenScribe",
            dependencies: ["OpenScribeCore", "OpenScribeUI"],
            path: "Sources/TranscribeApp"
        ),
        // Test target: sadece saf Swift modeller — AVFoundation yüklenmez
        .testTarget(
            name: "TranscribeAppTests",
            dependencies: ["OpenScribeModels"],
            path: "Tests/TranscribeAppTests"
        ),
    ]
)
