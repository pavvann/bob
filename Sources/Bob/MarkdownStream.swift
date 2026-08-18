import SwiftUI

// MARK: - the incremental parser

/// The streaming half of ``Markdown/parse(_:)``: the same blocks, discovered
/// as the text arrives instead of re-derived from the whole message on every
/// flush — that re-derivation was O(M²) over a reply and the bulk of what
/// streaming cost.
///
/// A block commits only once later text cannot change it, and the rules are
/// the whole correctness story:
/// - a blank line outside a fence commits everything above it — every
///   accumulating block (paragraph, list, quote, table) stops at one, and a
///   blank line can never be reinterpreted by what follows;
/// - a closing fence line commits the fence it seals — nothing reaches back
///   into a closed fence, and a fence line can't become a table header;
/// - everything nearer the frontier stays unstable: the line before it may
///   yet turn out to be a table header waiting on its delimiter row, an open
///   fence swallows lines until it closes, and the last line has no newline;
/// - ``finalize()`` commits the remaining tail through the normal parse, so
///   a finished message is block-for-block what a cold parse would produce.
///
/// Committed blocks are handed out exactly once and not retained: the caller
/// keeps its own rendered form, and holding the raw strings here as well
/// would duplicate most of a long transcript's text for its lifetime. All
/// this keeps is the tail — the only region the commit scan re-reads.
struct IncrementalBlocks {
    /// Text past the last stable boundary, newline-normalized. It always
    /// starts at a block boundary, so parsing it alone parses it correctly.
    private(set) var tail = ""

    /// The blocks this delta just made final.
    @discardableResult
    mutating func append(_ delta: String) -> [Markdown.Block] {
        // normalize \r\n only when one could exist — a pair can arrive split
        // across two deltas, visible only once both halves share the buffer
        if delta.contains("\r") || (delta.hasPrefix("\n") && tail.hasSuffix("\r")) {
            tail = (tail + delta).replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            tail += delta
        }
        return commitStablePrefix()
    }

    mutating func reset(_ text: String) {
        tail = text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// The message is done — nothing can reinterpret the tail any more.
    @discardableResult
    mutating func finalize() -> [Markdown.Block] {
        guard !tail.isEmpty else { return [] }
        defer { tail = "" }
        return Markdown.parse(tail)
    }

    /// The unstable region, parsed. What a renderer draws after the blocks
    /// it has already been handed.
    var tailBlocks: [Markdown.Block] { Markdown.parse(tail) }

    private mutating func commitStablePrefix() -> [Markdown.Block] {
        let lines = tail.components(separatedBy: "\n")
        var inFence = false
        var cut: Int?
        for index in 0..<(lines.count - 1) {   // the last line has no newline yet
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if Markdown.fence(trimmed) != nil {
                inFence.toggle()
                if !inFence { cut = index }    // sealed — the fence is final
            } else if !inFence, trimmed.isEmpty {
                cut = index                    // ends every open block above it
            }
        }
        guard let cut else { return [] }
        let fresh = Markdown.parse(lines[...cut].joined(separator: "\n"))
        tail = lines[(cut + 1)...].joined(separator: "\n")
        return fresh
    }
}

// MARK: - baked blocks

/// One block plus every AttributedString it will ever need, built exactly
/// once. Committed blocks carry these unchanged for the life of the entry,
/// so a flush re-derives nothing for text that has already landed.
struct RenderedBlock: Identifiable, Equatable {
    enum Content: Equatable {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case bullets([Item])
        case numbered([Item])
        case code(language: String?, body: String)
        case table(head: [AttributedString], rows: [[AttributedString]])
        case quote(AttributedString)
        case rule
    }

    struct Item: Equatable {
        let depth: Int
        let text: AttributedString
        let marker: String?
    }

    /// Persistent and monotonic per entry — never a position. A block keeps
    /// the id it was born with in the tail through commitment, so its view
    /// (and a code block's highlight state) survives the transition.
    let id: Int

    /// Still in the unstable tail. A fenced block keeps its streaming
    /// debounce while this is true; a committed one colours immediately.
    let live: Bool

    let content: Content

    /// The codeSize handed to `inline` per role matches what MarkdownText
    /// has always used — bake and view must agree or completed rows would
    /// shift on commit.
    init(id: Int, live: Bool, block: Markdown.Block, size: CGFloat,
         inline: (String, CGFloat) -> AttributedString) {
        self.id = id
        self.live = live
        switch block {
        case .paragraph(let body):
            content = .paragraph(inline(body, size - 1.5))
        case .heading(let level, let text):
            content = .heading(level: level, text: inline(text, size))
        case .bullets(let items):
            content = .bullets(items.map {
                Item(depth: $0.depth, text: inline($0.text, size - 1.5), marker: $0.marker)
            })
        case .numbered(let items):
            content = .numbered(items.map {
                Item(depth: $0.depth, text: inline($0.text, size - 1.5), marker: $0.marker)
            })
        case .code(let language, let body):
            content = .code(language: language, body: body)
        case .table(let head, let rows):
            content = .table(head: head.map { inline($0, size - 3.5) },
                             rows: rows.map { $0.map { inline($0, size - 3.5) } })
        case .quote(let body):
            content = .quote(inline(body, size - 2))
        case .rule:
            content = .rule
        }
    }
}

// MARK: - per-entry render model

/// A bob row's markdown, parsed once. Owned by its TranscriptEntry and fed
/// by TranscriptStore writes — never derived inside a SwiftUI body. Each
/// flush re-parses only the unstable tail; committed blocks keep their built
/// strings and their ids for the life of the entry, so the transcript's
/// ForEach never re-identifies a block mid-stream.
@MainActor
@Observable
final class MarkdownRenderModel {

    /// Committed blocks then the freshly-baked tail — everything the view
    /// draws, in order. The only observed property: one flush, one change.
    private(set) var blocks: [RenderedBlock] = []

    /// The transcript's reading size. The model bakes for the one surface
    /// that streams; MarkdownText serves anything sized differently.
    static let size: CGFloat = 16

    /// Highlighter cache identity, unique per entry (blocks add their id).
    let slot = UUID().uuidString

    @ObservationIgnored private var parser = IncrementalBlocks()
    @ObservationIgnored private var frozen: [RenderedBlock] = []
    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private var memo: [Piece: AttributedString] = [:]

    /// One inline run in the current tail, keyed by exact content. Kept only
    /// while the tail still holds it, so drafts of a growing message never
    /// accumulate — the only piece that misses per flush is the one the
    /// delta actually grew.
    private struct Piece: Hashable {
        let text: String
        let codeSize: CGFloat
    }

    /// Past this, inline-parsing a still-growing piece on every flush stops
    /// being free. A live piece this large renders plain until it commits —
    /// per piece and non-destructive, unlike the whole-tree ceiling this
    /// replaces: the block styles once, the moment it freezes.
    private static let livePieceCap = 24_000

    /// A row born with text (history, a restored turn) is already complete;
    /// one born empty is about to stream.
    init(text: String) {
        guard !text.isEmpty else { return }
        parser.reset(text)
        freeze(parser.finalize())
        blocks = frozen
    }

    func append(_ delta: String) {
        freeze(parser.append(delta))
        publishTail()
    }

    /// The whole text replaced (synthetic replies, error messages) — start
    /// over. Ids keep counting: reuse within an entry is what breaks views.
    func reset(_ text: String) {
        parser.reset(text)
        frozen = []
        memo = [:]
        publishTail()
    }

    /// Turn over: commit the tail through the normal parse, so the finished
    /// message is exactly what a cold parse would have rendered. Idempotent —
    /// a second finalize (a superseded legacy child, say) changes nothing.
    func finalize() {
        let fresh = parser.finalize()
        guard !fresh.isEmpty || blocks.count != frozen.count else { return }
        freeze(fresh)
        memo = [:]
        blocks = frozen
    }

    private func freeze(_ fresh: [Markdown.Block]) {
        for block in fresh {
            frozen.append(RenderedBlock(id: nextId, live: false, block: block,
                                        size: Self.size, inline: bakeFrozen))
            nextId += 1
        }
    }

    /// A freezing piece was usually built last flush as a tail piece — take
    /// the hit; store nothing, the result now lives in its RenderedBlock.
    /// Oversized pieces never entered the memo, so they style here, once.
    private func bakeFrozen(_ text: String, _ codeSize: CGFloat) -> AttributedString {
        memo[Piece(text: text, codeSize: codeSize)] ?? Markdown.inline(text, codeSize: codeSize)
    }

    private func publishTail() {
        var kept: [Piece: AttributedString] = [:]
        var id = nextId
        var tailBlocks: [RenderedBlock] = []
        for block in parser.tailBlocks {
            tailBlocks.append(RenderedBlock(id: id, live: true, block: block,
                                            size: Self.size) { text, codeSize in
                guard text.utf8.count <= Self.livePieceCap else { return AttributedString(text) }
                let piece = Piece(text: text, codeSize: codeSize)
                if let hit = kept[piece] ?? memo[piece] {
                    kept[piece] = hit
                    return hit
                }
                let built = Markdown.inline(text, codeSize: codeSize)
                kept[piece] = built
                return built
            })
            id += 1
        }
        memo = kept
        blocks = frozen + tailBlocks
    }
}

// MARK: - the streaming view

/// A reply drawn from its render model. Committed blocks render their cached
/// strings untouched; only the tail re-bakes per flush; and ids persist, so
/// a fence that closes keeps its view — and its highlight — as it freezes.
struct StreamedMarkdownText: View {
    let model: MarkdownRenderModel

    var body: some View {
        MarkdownBlocksView(blocks: model.blocks, size: MarkdownRenderModel.size,
                           slot: model.slot)
    }
}
