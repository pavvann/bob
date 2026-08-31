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
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.21"),

        // A real vt100/xterm emulator over a pty. `vi` needs an alternate screen
        // buffer, cursor addressing and keyboard modes on day one, so this is a
        // dependency rather than something to hand-roll. MIT, macOS 11 against
        // bob's 14, and the emulator already shipping in Secure Shellfish, La
        // Terminal and CodeEdit. It renders in AppKit, outside SwiftUI's
        // transaction system, so terminal output cannot invalidate the window.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
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
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "TreeSitterGrammars"
            ],
            path: "Sources/Bob"
        )
    ]
)
