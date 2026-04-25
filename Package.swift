// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "TranscribeApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TranscribeApp",
            path: "Sources/TranscribeApp",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "TranscribeAppTests",
            dependencies: ["TranscribeApp"],
            path: "Tests/TranscribeAppTests"
        ),
    ]
)
