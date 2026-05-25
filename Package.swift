// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bob",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bob",
            path: "Sources/Bob"
        )
    ]
)
