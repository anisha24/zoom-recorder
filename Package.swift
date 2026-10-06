// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZoomRecorder",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ZoomRecorder", path: "Sources/ZoomRecorder")
    ],
    swiftLanguageModes: [.v5]
)
