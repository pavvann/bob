import Foundation
import SwiftTreeSitter
import TreeSitterGrammars

/// A language bob can highlight.
///
/// bob's own type, deliberately, though nothing outside this file needs to know
/// that: detection hands one of these back and the highlighter takes it straight,
/// so no view imports a grammar package or learns a second vocabulary for "this
/// is Swift".
///
/// It exists because the grammar package's equivalent resolves its parser through
/// a single switch over all forty grammars it ships. Linking that switch
/// references all forty C entry points, the linker duly pulls all forty parsers
/// out of the static archive, and Bob.app weighs 101MB. A row here names exactly
/// one entry point, so the archive gives up exactly one parser.
struct SyntaxLanguage: Sendable {

    /// Canonical name. Identity, cache key, and — by convention, not by rule —
    /// the fence label a reader would type.
    let id: String

    /// Every fence spelling and file extension that resolves here. One flat set
    /// per language instead of a second alias table: `ts`, `typescript` and
    /// `app.ts` are the same question and deserve the same answer in one place.
    let hints: Set<String>

    /// Highlight queries to concatenate, as `<grammar directory>/<file>`,
    /// **most specific first** — a query listing its precise rules before its
    /// catch-alls is how tree-sitter expects to be read, and ``SyntaxHighlighter``
    /// resolves ties in that order. TypeScript puts its own rules ahead of the
    /// JavaScript ones it inherits; drop the inherited half and half the language
    /// goes uncoloured.
    let queries: [String]

    /// The grammar's C entry point in the tree-sitter archive.
    ///
    /// Held as a function rather than a resolved pointer so the table stays a list
    /// of literals, and so a grammar is only touched once something asks to
    /// highlight in it.
    let entry: @convention(c) () -> OpaquePointer?

    /// The grammar, ready for a `Parser`.
    var grammar: Language? { entry().map(Language.init(language:)) }
}

extension SyntaxLanguage: Hashable {

    // Identity is the name. Two rows with the same `id` would be the same
    // language, and `entry` — a function — has no equality worth speaking of.
    static func == (lhs: SyntaxLanguage, rhs: SyntaxLanguage) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension SyntaxLanguage {

    /// Every language bob ships a parser for.
    ///
    /// **To add a language: add one row here.** That row is the only thing that
    /// puts a parser in the binary — `Sources/TreeSitterGrammars/grammars.h`
    /// already declares all forty entry points, and a declaration nobody
    /// references costs nothing. Check the grammar's query directory name against
    /// the package's `Resources/tree-sitter-*` folders; it isn't always the
    /// obvious one (TSX highlights out of `tree-sitter-typescript`).
    ///
    /// Ten, because ten is what bob's transcripts and file viewer actually show.
    /// Anything absent renders plain, which is a correct rendering of code bob
    /// can't read.
    static let all: [SyntaxLanguage] = [
        .init(id: "swift",      hints: ["swift"],                                queries: ["swift/highlights"],                              entry: tree_sitter_swift),
        .init(id: "typescript", hints: ["ts", "typescript", "cts", "mts"],       queries: ["typescript/highlights", "javascript/highlights"], entry: tree_sitter_typescript),
        .init(id: "tsx",        hints: ["tsx"],                                  queries: ["typescript/highlights", "javascript/highlights"], entry: tree_sitter_tsx),
        .init(id: "javascript", hints: ["js", "javascript", "cjs", "mjs"],       queries: ["javascript/highlights"],                         entry: tree_sitter_javascript),
        .init(id: "python",     hints: ["py", "python", "python2", "python3"],   queries: ["python/highlights"],                             entry: tree_sitter_python),
        .init(id: "json",       hints: ["json"],                                 queries: ["json/highlights"],                               entry: tree_sitter_json),
        .init(id: "yaml",       hints: ["yml", "yaml"],                          queries: ["yaml/highlights"],                               entry: tree_sitter_yaml),
        .init(id: "bash",       hints: ["sh", "bash", "shell", "zsh", "console"], queries: ["bash/highlights"],                              entry: tree_sitter_bash),
        .init(id: "rust",       hints: ["rs", "rust"],                           queries: ["rust/highlights"],                               entry: tree_sitter_rust),
        .init(id: "go",         hints: ["go", "golang"],                         queries: ["go/highlights"],                                 entry: tree_sitter_go)
    ]

    /// Every hint, resolved. Built once; a duplicate hint quietly keeps the first
    /// row rather than trapping, because a table typo shouldn't take a running app
    /// down over a code block.
    static let byHint: [String: SyntaxLanguage] = Dictionary(
        all.flatMap { language in language.hints.map { ($0, language) } },
        uniquingKeysWith: { first, _ in first })
}

/// One painted role.
///
/// Grammars report far more capture names than this — `string.special`,
/// `function.call`, `type.builtin`, and a long tail that differs per language.
/// All of them fold into a role ``SyntaxTheme`` can actually colour, and
/// anything unrecognised reads as ``plain``. The taxonomy stops where the
/// palette stops; that's the point.
enum SyntaxToken: UInt8, Sendable {
    case keyword, string, number, comment, type, function, variable, punctuation, plain

    /// Fold a tree-sitter capture name into a role, matching on the leading
    /// component so `string.escape` lands with `string` and a grammar inventing
    /// `keyword.coroutine` tomorrow still reads as a keyword.
    init(capture name: String) {
        let head = name.prefix { $0 != "." }
        switch head {
        case "keyword", "conditional", "repeat", "include", "import", "exception",
             "boolean", "constant", "storageclass", "modifier":
            self = .keyword
        case "string", "character":
            self = .string
        case "number", "float", "integer":
            self = .number
        case "comment", "spell":
            self = .comment
        case "type", "class", "struct", "enum", "interface", "namespace", "module", "constructor":
            self = .type
        case "function", "method":
            self = .function
        case "variable", "property", "field", "parameter", "attribute", "label", "tag", "symbol":
            self = .variable
        case "punctuation", "operator", "delimiter", "bracket":
            self = .punctuation
        default:
            self = .plain
        }
    }
}

/// A run of one role over a stretch of source.
///
/// `range` is an `NSRange` in UTF-16 code units. tree-sitter parses bob's
/// strings as UTF-16LE, so these need no conversion to reach an
/// `AttributedString`. Spans arrive sorted, never overlapping, and never
/// ``SyntaxToken/plain`` — an unpainted stretch is simply absent, which leaves
/// the renderer's base colour showing through.
struct SyntaxSpan: Sendable, Equatable {
    let range: NSRange
    let token: SyntaxToken
}

/// Turns source into coloured spans, off the main thread.
///
/// An actor for two reasons: a 400KB file must not parse on the main thread, and
/// serialising the work means a streaming transcript that re-renders on every
/// token can't start a stampede of parallel parses. Results are cached by
/// content, so that re-render is free after the first pass.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    /// Number of real parses performed. Only interesting to tests — it's how you
    /// prove the cache is doing its job.
    private(set) var parses = 0

    private struct Key: Hashable {
        let content: Int
        let language: String
    }

    /// Small on purpose. A reader looks at one file and a handful of fenced
    /// blocks at a time; holding more spans than that is just retained memory.
    private static let capacity = 24

    private var cache: [Key: [SyntaxSpan]] = [:]
    private var recency: [Key] = []      // oldest first

    /// Compiled queries, kept for the life of the process. There are only ten of
    /// them and compiling one is far dearer than parsing a small file.
    private var queries: [String: Query] = [:]

    /// Spans for `source` read as `language`. Cached — calling this on every
    /// frame of a streaming transcript costs one parse, not one per frame.
    func spans(for source: String, language: SyntaxLanguage) -> [SyntaxSpan] {
        let key = Key(content: source.hashValue, language: language.id)
        if let hit = cache[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return hit
        }

        let spans = parse(source, language)

        cache[key] = spans
        recency.append(key)
        if recency.count > Self.capacity {
            cache.removeValue(forKey: recency.removeFirst())
        }
        return spans
    }

    private func parse(_ source: String, _ language: SyntaxLanguage) -> [SyntaxSpan] {
        // No grammar or no highlight query means no opinion — plain text is a
        // correct rendering of code bob can't read.
        guard let grammar = language.grammar,
              let query = query(for: language, grammar: grammar) else { return [] }

        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(source) else { return [] }

        parses += 1

        let highlights = query
            .execute(in: tree)
            .resolve(with: .init(string: source))
            .highlights()

        return Self.flatten(highlights, length: source.utf16.count)
    }

    /// The compiled highlight query for a language.
    ///
    /// bob loads the `.scm` files itself rather than going through the grammar
    /// package's own accessor, for two reasons. The package builds its paths from
    /// `Bundle.module.resourceURL` plus a literal `Resources/` component, which
    /// only lines up under Xcode's bundle layout — under `swift build` the bundle
    /// is shallow, CFBundle already reports `<bundle>/Resources` as the resource
    /// root, the two `Resources` double up and *every* query silently comes back
    /// nil. bob assembles Bob.app by hand, so it has to resolve this itself.
    ///
    /// The second reason is that the package concatenates `folds`, `indents`,
    /// `locals` and `tags` into the highlight query. Those aren't colour queries;
    /// their captures describe folding and scope. Only `highlights*` files count,
    /// which is why ``SyntaxLanguage/queries`` names them one by one.
    ///
    /// A missing or uncompilable file is not an error worth reporting: the
    /// language simply goes unpainted.
    private func query(for language: SyntaxLanguage, grammar: Language) -> Query? {
        if let cached = queries[language.id] { return cached }
        guard let root = Self.queryRoot else { return nil }

        let source = language.queries
            .map { Self.scm(root, $0) }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        guard !source.isEmpty,
              let compiled = try? Query(language: grammar, data: Data(source.utf8)) else { return nil }

        queries[language.id] = compiled
        return compiled
    }

    /// The directory holding the `tree-sitter-*` query folders, wherever the
    /// grammar bundle ended up — `.build` during development, `Bob.app`'s
    /// resources once bundled.
    static let queryRoot: URL? = {
        let bundleName = "CodeEditLanguages_CodeEditLanguages.bundle"
        let roots = [Bundle.main.resourceURL,
                     Bundle.main.bundleURL,
                     Bundle.main.bundleURL.deletingLastPathComponent()]
            .compactMap { $0?.appendingPathComponent(bundleName) }

        for bundle in roots {
            // Xcode nests one deeper than the SPM command-line layout does.
            for inner in ["Resources", "Contents/Resources/Resources", "Contents/Resources", ""] {
                let candidate = inner.isEmpty ? bundle : bundle.appendingPathComponent(inner)
                let sentinel = scm(candidate, "swift/highlights")
                if FileManager.default.fileExists(atPath: sentinel.path) { return candidate }
            }
        }
        return nil
    }()

    /// A `<grammar directory>/<file>` query name, resolved inside the bundle.
    static func scm(_ root: URL, _ query: String) -> URL {
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return root }
        return root.appendingPathComponent("tree-sitter-\(parts[0])", isDirectory: true)
            .appendingPathComponent("\(parts[1]).scm")
    }

    /// Resolve tree-sitter's overlapping captures into a flat, ordered list.
    ///
    /// Captures nest — an f-string encloses the expression interpolated into it,
    /// a call expression encloses its own name. Painting widest-first lets the
    /// innermost capture win the characters it covers, which is what "nested
    /// highlighting" means to a reader.
    private static func flatten(_ ranges: [NamedRange], length: Int) -> [SyntaxSpan] {
        guard length > 0 else { return [] }

        var paint = [SyntaxToken](repeating: .plain, count: length)

        // Widest first, so a narrower capture nested inside a wider one wins the
        // characters it covers. Among captures of *equal* width, later ones paint
        // first so the earliest survives: that's tree-sitter's convention, where
        // a query lists its specific rules before its catch-alls. `Map` in
        // `new Map<…>()` matches an uppercase-constructor rule and then a bare
        // `(identifier) @variable`; first-wins is what makes it read as a type.
        // The index tiebreak is also what keeps this deterministic — `sorted`
        // isn't stable, so without it the same file could colour differently
        // between runs.
        let ordered = ranges.enumerated().sorted {
            $0.element.range.length != $1.element.range.length
                ? $0.element.range.length > $1.element.range.length
                : $0.offset > $1.offset
        }

        for (_, named) in ordered {
            let token = SyntaxToken(capture: named.name)
            guard token != .plain else { continue }
            let lower = max(0, named.range.location)
            let upper = min(length, named.range.location + named.range.length)
            guard lower < upper else { continue }
            for index in lower..<upper { paint[index] = token }
        }

        var spans: [SyntaxSpan] = []
        var index = 0
        while index < length {
            let token = paint[index]
            var end = index + 1
            while end < length, paint[end] == token { end += 1 }
            if token != .plain {
                spans.append(SyntaxSpan(range: NSRange(location: index, length: end - index),
                                        token: token))
            }
            index = end
        }
        return spans
    }
}

extension SyntaxHighlighter {

    /// Resolve a language from a file name, a bare extension, or a markdown
    /// fence info string — the three ways bob ever learns what it's looking at.
    ///
    /// One function and one table, because `"ts"`, `"typescript"` and
    /// `"src/app.ts"` all deserve the same answer. Returns `nil` for anything bob
    /// has no parser for, which callers should read as "render this plainly" —
    /// and that covers `txt`, `log`, `text` and a bare fence for free, without a
    /// list of things not to colour.
    static func language(for hint: String) -> SyntaxLanguage? {
        // Fence info strings carry extras: ```swift title="Foo.swift"
        guard var token = hint.lowercased()
            .split(whereSeparator: { " \t,:;{".contains($0) })
            .first.map(String.init), !token.isEmpty else { return nil }

        // A path or file name reduces to its extension; a bare "swift" stays put.
        // Names that *are* the identifier (Dockerfile, Makefile) have no dot.
        if let dot = token.lastIndex(of: "."), dot != token.startIndex {
            token = String(token[token.index(after: dot)...])
        }

        return SyntaxLanguage.byHint[token]
    }
}
