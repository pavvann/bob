// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bob",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 40+ tree-sitter grammars and their highlight queries in one binary
        // xcframework. SwiftTreeSitter (the parser + query runtime) rides along
        // transitively — one dependency instead of one per language.
        //
        // bob links the archive and reads the `.scm` queries out of the package's
        // resource bundle, but does *not* import its `CodeLanguage` type: see
        // Sources/TreeSitterGrammars/include/grammars.h.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.21")
    ],
    targets: [
        // Names the grammars in that archive, and decides which of them reach the
        // binary: ten declarations bob references, thirty definitions that stop
        // the linker loading a parser nobody asked for. Worth 89MB of Bob.app —
        // see Sources/TreeSitterGrammars/grammars.c.
        .target(name: "TreeSitterGrammars", path: "Sources/TreeSitterGrammars"),

        .executableTarget(
            name: "Bob",
            dependencies: [
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                "TreeSitterGrammars"
            ],
            path: "Sources/Bob"
        )
    ]
)
