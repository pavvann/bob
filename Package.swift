// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bob",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 40+ tree-sitter grammars and their highlight queries in one binary
        // xcframework. SwiftTreeSitter (the parser + query runtime) rides along
        // transitively — one dependency instead of one per language.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.21")
    ],
    targets: [
        .executableTarget(
            name: "Bob",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages")
            ],
            path: "Sources/Bob"
        )
    ]
)
