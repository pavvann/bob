import Foundation

/// Canvas boards. A board is a markdown file in `~/bob/canvas/` — H1 +
/// `<!-- canvas v1 -->` marks it, every `## heading` is one draggable card,
/// and an optional `<!-- @ x,y -->` on the heading line is its position.
/// The parser is deliberately conservative: prose before the first card is
/// kept verbatim, `## ` inside fenced code blocks is body (not a boundary),
/// and comment tokens it doesn't understand ride along untouched.

/// A comment token on a card's heading line.
enum HeadingToken: Equatable {
    case position(x: Int, y: Int)
    case other(String)          // raw comment body, preserved verbatim

    var inner: String {
        switch self {
        case .position(let x, let y): return "@ \(x),\(y)"
        case .other(let s): return s
        }
    }

    static func classify(_ inner: String) -> HeadingToken {
        guard inner.hasPrefix("@") else { return .other(inner) }
        let parts = inner.dropFirst().split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return .other(inner) }
        return .position(x: x, y: y)
    }
}

/// One `## heading` section — a card. Identity is positional within a parse.
struct CanvasCard: Identifiable {
    let id = UUID()
    var title: String
    var tokens: [HeadingToken]
    var bodyLines: [String]
    /// Heading line exactly as read from disk; emitted verbatim on write
    /// until the heading is deliberately changed (title or position).
    var rawHeading: String?

    var position: CGPoint? {
        for case let .position(x, y) in tokens { return CGPoint(x: x, y: y) }
        return nil
    }

    var attribution: String? {
        for case let .other(s) in tokens where s.hasPrefix("by ") { return s }
        return nil
    }

    /// Body as shown/edited in the UI — separator blank lines trimmed.
    var displayBody: String {
        var lines = bodyLines
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    var headingLine: String {
        if let raw = rawHeading { return raw }
        return tokens.reduce("## " + title) { $0 + " <!-- \($1.inner) -->" }
    }

    mutating func setPosition(_ p: CGPoint) {
        let token = HeadingToken.position(x: Int(p.x.rounded()), y: Int(p.y.rounded()))
        if let i = tokens.firstIndex(where: { if case .position = $0 { return true } else { return false } }) {
            tokens[i] = token
        } else {
            tokens.insert(token, at: 0)
        }
        rawHeading = nil
    }

    mutating func setTitle(_ t: String) {
        guard t != title else { return }
        title = t
        rawHeading = nil
    }

    mutating func setBody(_ text: String) {
        bodyLines = text.isEmpty ? [""] : text.components(separatedBy: "\n") + [""]
    }
}

/// A parsed board document. Serialization is line-faithful: every line we
/// didn't deliberately change comes back byte-identical.
struct CanvasBoard {
    var preambleLines: [String]
    var cards: [CanvasCard]
    var isBoard: Bool

    static let cardNominalSize = CGSize(width: 220, height: 140)

    static func parse(_ text: String) -> CanvasBoard {
        let lines = text.components(separatedBy: "\n")
        var preamble: [String] = []
        var cards: [CanvasCard] = []
        var fence: (char: Character, count: Int)? = nil

        func content(_ line: String) {
            if cards.isEmpty { preamble.append(line) } else { cards[cards.count - 1].bodyLines.append(line) }
        }

        for line in lines {
            if let run = fenceRun(line) {
                if let open = fence {
                    if run.char == open.char, run.count >= open.count, run.trailing.isEmpty { fence = nil }
                } else {
                    fence = (run.char, run.count)
                }
                content(line)
            } else if fence == nil, line.hasPrefix("## ") {
                let h = parseHeading(line)
                cards.append(CanvasCard(title: h.title, tokens: h.tokens, bodyLines: [], rawHeading: line))
            } else {
                content(line)
            }
        }
        let isBoard = preamble.contains { $0.hasPrefix("# ") }
            && preamble.contains { $0.contains("<!-- canvas v1 -->") }
        return CanvasBoard(preambleLines: preamble, cards: cards, isBoard: isBoard)
    }

    /// ``` or ~~~ fence line: (delimiter char, run length, text after the run).
    private static func fenceRun(_ line: String) -> (char: Character, count: Int, trailing: String)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        return (first, run.count, rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces))
    }

    /// Splits `## title <!-- ... --> <!-- ... -->` into title + tokens.
    /// Unterminated comments fold back into the title so nothing is lost.
    private static func parseHeading(_ line: String) -> (title: String, tokens: [HeadingToken]) {
        var rest = String(line.dropFirst(3))
        var title = ""
        var tokens: [HeadingToken] = []
        while let open = rest.range(of: "<!--") {
            title += rest[..<open.lowerBound]
            rest = String(rest[open.upperBound...])
            guard let close = rest.range(of: "-->") else {
                title += "<!--" + rest
                rest = ""
                break
            }
            tokens.append(.classify(String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)))
            rest = String(rest[close.upperBound...])
        }
        title += rest
        return (title.trimmingCharacters(in: .whitespaces), tokens)
    }

    func serialized() -> String {
        var lines = preambleLines
        for card in cards {
            lines.append(card.headingLine)
            lines.append(contentsOf: card.bodyLines)
        }
        return lines.joined(separator: "\n")
    }

    /// Cards with no `@` comment get grid-scan positions. Returns whether
    /// anything changed (caller writes the backfill back, debounced).
    mutating func autoPlaceMissing() -> Bool {
        let missing = cards.indices.filter { cards[$0].position == nil }
        guard !missing.isEmpty else { return false }
        let taken = cards.compactMap { $0.position.map { CGRect(origin: $0, size: Self.cardNominalSize) } }
        let spots = Self.gridPlacements(taken: taken, count: missing.count)
        for (i, idx) in missing.enumerated() where i < spots.count { cards[idx].setPosition(spots[i]) }
        return true
    }

    /// First free slots on a fixed grid, skipping any that overlap `taken`.
    static func gridPlacements(taken: [CGRect], count: Int, columns: Int = 4,
                               origin: CGPoint = CGPoint(x: 48, y: 48),
                               step: CGSize = CGSize(width: 252, height: 172)) -> [CGPoint] {
        var taken = taken
        var out: [CGPoint] = []
        var slot = 0
        while out.count < count && slot < 10_000 {
            let p = CGPoint(x: origin.x + CGFloat(slot % columns) * step.width,
                            y: origin.y + CGFloat(slot / columns) * step.height)
            slot += 1
            let rect = CGRect(origin: p, size: cardNominalSize)
            if taken.allSatisfy({ !$0.intersects(rect) }) {
                out.append(p)
                taken.append(rect)
            }
        }
        return out
    }
}

/// File-backed store for the canvas surface. Same shape as TodoService:
/// poll the file every 700ms, write back debounced + atomic. A dirty-position
/// guard keeps the poll from ever clobbering an in-flight drag or edit —
/// our debounced write wins, like notes.
@MainActor
final class CanvasStore: ObservableObject {
    static let shared = CanvasStore()

    struct BoardRef: Identifiable, Equatable {
        let name: String
        let url: URL
        var id: String { name }
    }

    @Published private(set) var boards: [BoardRef] = []
    @Published private(set) var board: CanvasBoard?
    @Published private(set) var boardName: String?

    /// Set by the surface while a card is being dragged / edited.
    var activeDragID: UUID?
    var editingHold = false

    private let root: URL
    private var lastDiskText = ""
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private var currentURL: URL? { boardName.map { root.appendingPathComponent($0 + ".md") } }
    var cards: [CanvasCard] { board?.cards ?? [] }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob/canvas", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        refreshBoards()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: boards

    func refreshBoards() {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var refs = files.filter { $0.pathExtension == "md" }
            .map { BoardRef(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
        if let i = refs.firstIndex(where: { $0.name == "scratch" }), i > 0 {
            refs.insert(refs.remove(at: i), at: 0)
        }
        if refs != boards { boards = refs }
    }

    /// First open of the surface: pick up where we were, else the first
    /// board on disk, else auto-create scratch.
    func openDefault() {
        refreshBoards()
        guard boardName == nil else { return }
        open(boards.first?.name ?? "scratch")
    }

    func open(_ name: String) {
        flush()
        boardName = name
        guard let url = currentURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("# \(name)\n<!-- canvas v1 -->\n".utf8).write(to: url, options: .atomic)
            refreshBoards()
        }
        adopt((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    // MARK: card CRUD

    @discardableResult
    func addCard(title: String = "", body: String = "", at point: CGPoint? = nil) -> UUID? {
        guard var b = board else { return nil }
        var card = CanvasCard(title: title, tokens: [], bodyLines: [], rawHeading: nil)
        card.setBody(body)
        let taken = b.cards.compactMap { $0.position.map { CGRect(origin: $0, size: CanvasBoard.cardNominalSize) } }
        card.setPosition(point ?? CanvasBoard.gridPlacements(taken: taken, count: 1).first ?? CGPoint(x: 48, y: 48))
        // one blank line between the previous section and the new heading
        if b.cards.isEmpty {
            if b.preambleLines.last != "" { b.preambleLines.append("") }
        } else if b.cards[b.cards.count - 1].bodyLines.last != "" {
            b.cards[b.cards.count - 1].bodyLines.append("")
        }
        b.cards.append(card)
        board = b
        scheduleSave()
        return card.id
    }

    func updateCard(_ id: UUID, title: String? = nil, body: String? = nil) {
        guard var b = board, let i = b.cards.firstIndex(where: { $0.id == id }) else { return }
        if let title { b.cards[i].setTitle(title) }
        if let body { b.cards[i].setBody(body) }
        board = b
        scheduleSave()
    }

    func moveCard(_ id: UUID, to p: CGPoint) {
        guard var b = board, let i = b.cards.firstIndex(where: { $0.id == id }) else { return }
        b.cards[i].setPosition(p)
        board = b
        scheduleSave()
    }

    func deleteCard(_ id: UUID) {
        guard var b = board, let i = b.cards.firstIndex(where: { $0.id == id }) else { return }
        b.cards.remove(at: i)
        board = b
        scheduleSave()
    }

    /// Write pending changes now (board switch, surface dismissal).
    func flush() {
        saveTask?.cancel()
        saveNow()
    }

    // MARK: disk

    private func adopt(_ text: String) {
        lastDiskText = text
        var parsed = CanvasBoard.parse(text)
        if parsed.autoPlaceMissing() { scheduleSave() }
        board = parsed
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard dirty, let b = board, let url = currentURL else { return }
        let text = b.serialized()
        try? Data(text.utf8).write(to: url, options: .atomic)
        lastDiskText = text
        dirty = false
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func tick() {
        refreshBoards()
        // dirty-position guard: a poll never clobbers unsaved local state.
        guard !dirty, activeDragID == nil, !editingHold, let url = currentURL else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8), text != lastDiskText else { return }
        adopt(text)
    }
}
