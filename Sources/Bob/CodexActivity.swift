import Foundation
import Observation

// MARK: - a bounded tail of output

/// What bob keeps of a command's output: the last few lines, and nothing else.
///
/// `item/commandExecution/outputDelta` is a firehose with no ceiling — a `cat`
/// of a 50MB file arrives here as megabytes per coalescing window — and the rail
/// can show three or four lines of it. So the retention is the display's own
/// budget rather than the stream's: **the last 64 lines, each clipped at 512
/// characters**, about 32KB worst case per command and a few hundred bytes in
/// practice. Anything thrown away sets `clipped`, because a row that silently
/// drops the head of its output is lying about what ran.
///
/// The clip happens before the split, which is the part that matters: splitting
/// a megabyte chunk into lines just to keep the last four would allocate a
/// substring per line of the whole firehose.
struct CodexOutputTail: Sendable, Equatable {
    static let maxLines = 64
    static let maxLineChars = 512

    private(set) var lines: [String] = []
    private(set) var clipped = false
    /// The last line has no newline yet, so the next chunk continues it.
    private var openLine = false

    var isEmpty: Bool { visibleLines.isEmpty }

    /// Trailing blank lines are what a shell prompt would have eaten; in a
    /// 218pt gutter they are wasted rows.
    var visibleLines: [String] {
        var out = lines
        while let last = out.last, last.isEmpty { out.removeLast() }
        return out
    }

    /// The authoritative `aggregatedOutput` on `item/completed`, reduced to the
    /// same tail. Built in the decoder so the full string is released off the
    /// main actor and never reaches a published surface.
    static func tail(of full: String) -> CodexOutputTail {
        var tail = CodexOutputTail()
        tail.append(full)
        return tail
    }

    mutating func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let incoming = clipToBudget(chunk)
        let endsWithNewline = incoming.hasSuffix("\n")
        var pieces = incoming.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline { pieces.removeLast() }   // the empty piece after the final \n
        if openLine, !lines.isEmpty, let first = pieces.first {
            let merged = clip(lines[lines.count - 1] + first)
            lines[lines.count - 1] = merged
            pieces.removeFirst()
        }
        for piece in pieces {
            let line = clip(piece)
            lines.append(line)
        }
        openLine = !endsWithNewline
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
            clipped = true
        }
    }

    /// Keep only as much of the incoming chunk as could possibly survive the
    /// caps. `utf8.count` rather than `count` on purpose: the byte count is
    /// stored on a native Swift string, the character count is a walk.
    private mutating func clipToBudget(_ chunk: String) -> String {
        let budget = Self.maxLines * Self.maxLineChars
        guard chunk.utf8.count > budget else { return chunk }
        clipped = true
        // decoding repairs whatever scalar the byte-wise cut landed inside
        return String(decoding: chunk.utf8.suffix(budget), as: UTF8.self)
    }

    private mutating func clip(_ line: String) -> String {
        // a carriage return returns to column zero, so a progress bar's line is
        // whatever followed the last one — which is also what makes \r\n endings
        // land clean
        var text = line
        if text.contains("\r") { text = String(text.split(separator: "\r", omittingEmptySubsequences: false).last ?? "") }
        guard text.utf8.count > Self.maxLineChars else { return text }
        clipped = true
        return String(text.prefix(Self.maxLineChars))
    }
}

// MARK: - one row

/// One typed thing codex did. A reference type for the same reason a
/// `TranscriptEntry` is: a running command's output grows in place, and with
/// Observation that wakes the one row reading it rather than the whole rail.
@MainActor
@Observable
final class CodexActivityRow: Identifiable {
    enum Kind: Equatable {
        case command
        case tool
        case search
        case fileChange

        /// `terminal` is deliberately the same glyph claude's backgrounded
        /// commands wear in this gutter — it is the same fact about the world.
        var symbol: String {
            switch self {
            case .command: return "terminal"
            case .tool: return "puzzlepiece.extension"
            case .search: return "magnifyingglass"
            case .fileChange: return "square.and.pencil"
            }
        }
    }

    /// The item id — codex's own, so a start and its completion find each other.
    let id: String
    let kind: Kind
    let turnId: String
    fileprivate(set) var title: String
    fileprivate(set) var subtitle: String?
    fileprivate(set) var status: CodexWorkStatus
    fileprivate(set) var exitCode: Int?
    fileprivate(set) var durationMs: Int?
    fileprivate(set) var output = CodexOutputTail()

    init(id: String, kind: Kind, turnId: String, title: String,
         subtitle: String? = nil, status: CodexWorkStatus) {
        self.id = id
        self.kind = kind
        self.turnId = turnId
        self.title = title
        self.subtitle = subtitle
        self.status = status
    }

    var isRunning: Bool { status == .inProgress }

    /// A non-zero exit is a failure whatever the item's own status says. Codex
    /// reports `completed` for a command that ran fine and exited 3 — the shell
    /// did what it was told — but on screen that has to read as a failure.
    var failed: Bool { status == .failed || (exitCode ?? 0) != 0 }

    /// The line under the title. Exit code first, because it is the answer to
    /// the only question a finished command raises; everything else is a quiet
    /// aside behind it.
    var caption: String? {
        var parts: [String] = []
        if let code = exitCode, code != 0 {
            parts.append("exit \(code)")
        } else if status == .declined {
            parts.append("declined")
        } else if status == .failed {
            parts.append("failed")
        } else if status == .completed, let ms = durationMs, ms >= 100 {
            parts.append(Self.spell(ms))
        }
        if let subtitle { parts.append(subtitle) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func spell(_ ms: Int) -> String {
        ms < 1000 ? "\(ms)ms" : String(format: "%.1fs", Double(ms) / 1000)
    }
}

// MARK: - reasoning

/// The thinking row's content — the newest reasoning item only.
///
/// Scoped to one item on purpose: this answers "what is it working through now",
/// and a session's whole reasoning history would both bury the activity rows and
/// grow without a ceiling. Bounded the same way everything else here is: the
/// last 8 summary parts at 2000 characters each, and 4000 characters of raw
/// text.
@MainActor
@Observable
final class CodexReasoningRow: Identifiable {
    static let maxParts = 8
    static let maxPartChars = 2000
    static let maxRawChars = 4000

    let id: String
    fileprivate(set) var parts: [String] = []
    /// `item/reasoning/textDelta` — model-dependent, and absent on most. Detail
    /// behind the summary rather than the thing the row is about.
    fileprivate(set) var raw: String = ""
    fileprivate(set) var isLive = true

    init(id: String) { self.id = id }

    /// Only the parts the model actually wrote into: `summaryPartAdded` can
    /// announce a part that never receives a word, and a blank paragraph in the
    /// gutter is worse than a missing one.
    var summary: [String] {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isEmpty: Bool {
        summary.isEmpty && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - the store

/// Codex's activity, on its own observation axis — the peer of
/// `TranscriptStore` and for the same reason (P2b): output deltas and reasoning
/// deltas are firehoses, and routing them through the session's
/// `objectWillChange` would redraw the stage sixty times a second. Nothing here
/// is `@Published`; a growing row wakes only the view reading that row.
@MainActor
@Observable
final class CodexActivityStore {
    /// Oldest first, so the gutter reads top-down in the order things happened.
    private(set) var rows: [CodexActivityRow] = []
    private(set) var reasoning: CodexReasoningRow?
    /// `turn/diff/updated`'s tally, and only the tally — see `CodexDiffTally`.
    private(set) var turnDiff: CodexDiffTally?
    private var diffTurnId: String?

    /// Enough history for the "done" fold to be worth opening, and a hard
    /// ceiling so a long session can't accumulate rows forever. Running rows
    /// are never dropped: they are the answer to "what is happening now".
    static let maxRows = 40

    private var index: [String: CodexActivityRow] = [:]
    /// The session's own directory. A command's `cwd` is only worth a word when
    /// it is somewhere else — which, given the sandbox, is news.
    private let scope: String?

    init(scope: String? = nil) {
        self.scope = scope.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    // MARK: items

    /// One `item/started` or `item/completed`, folded into the row it owns.
    ///
    /// The same call serves both ends because codex re-sends the whole item on
    /// completion — so a row whose start bob never saw (a route that came up
    /// late) still lands complete, and a dropped delta heals from
    /// `aggregatedOutput` here.
    func record(_ item: CodexItem, done: Bool) {
        switch item.content {
        case .commandExecution(let run):
            let row = row(for: item, kind: .command, title: run.command, status: run.status)
            set(&row.title, run.command)
            set(&row.status, run.status)
            set(&row.exitCode, run.exitCode)
            set(&row.durationMs, run.durationMs)
            set(&row.subtitle, elsewhere(run.cwd))
            // the item's own aggregate is authoritative; the guard keeps the
            // re-clip out of the common case, where the stream already matches
            if let full = run.output, full != row.output { row.output = full }
        case .mcpToolCall(let server, let tool, let status):
            let row = row(for: item, kind: .tool, title: "\(server) · \(tool)", status: status)
            set(&row.status, status)
        case .webSearch(let query):
            // web search has no status of its own — it is running until its
            // completion arrives
            let row = row(for: item, kind: .search, title: query, status: .inProgress)
            set(&row.status, done ? .completed : .inProgress)
        case .fileChange(let changes, let status):
            let row = row(for: item, kind: .fileChange,
                          title: Self.title(for: changes), status: status)
            set(&row.title, Self.title(for: changes))
            set(&row.subtitle, Self.kinds(of: changes))
            set(&row.status, status)
        case .reasoning(let summary, let content):
            // completion only, and only with words in it: `item/started` for a
            // reasoning item arrives empty, and a model that emits no reasoning
            // at all must leave no row behind
            guard done else { break }
            seed(reasoning: item.id, summary: summary, content: content)
        case .userMessage, .agentMessage, .other:
            break
        }
    }

    /// Streamed output for a running command. An unknown item is dropped rather
    /// than given a row: a row whose command line bob never saw would name
    /// nothing, and `item/completed`'s `aggregatedOutput` heals it a moment
    /// later anyway.
    func append(output chunk: String, toCommand id: String) {
        guard let row = index[id], row.kind == .command else { return }
        row.output.append(chunk)
    }

    /// app-server is gone, which is exactly what reaps the children a
    /// `turn/interrupt` never could — so nothing that was running still is.
    func endRunning(reason: String) {
        for row in rows where row.status == .inProgress {
            row.status = .failed
            if row.caption == nil { row.subtitle = reason }
        }
    }

    // MARK: the turn's diff

    func note(diff: CodexDiffTally, turnId: String) {
        if diffTurnId != turnId {
            diffTurnId = turnId
            turnDiff = nil
        }
        guard turnDiff != diff else { return }
        turnDiff = diff.isEmpty ? nil : diff
    }

    // MARK: reasoning

    func append(reasoning text: String, part: Int, item: String) {
        let row = liveReasoning(item)
        reserve(part: part, on: row)
        guard part < row.parts.count else { return }
        let grown = row.parts[part] + text
        row.parts[part] = grown.count > CodexReasoningRow.maxPartChars
            ? String(grown.suffix(CodexReasoningRow.maxPartChars))
            : grown
    }

    func append(reasoningText text: String, item: String) {
        let row = liveReasoning(item)
        let grown = row.raw + text
        row.raw = grown.count > CodexReasoningRow.maxRawChars
            ? String(grown.suffix(CodexReasoningRow.maxRawChars))
            : grown
    }

    /// `item/reasoning/summaryPartAdded`. Deliberately not row-creating: an
    /// announced part with nothing in it is not reasoning, and a row that
    /// appeared for one would be the empty placeholder this must never draw.
    func reserveReasoning(part: Int, item: String) {
        guard let row = reasoning, row.id == item else { return }
        reserve(part: part, on: row)
    }

    func endReasoning() {
        guard let row = reasoning, row.isLive else { return }
        row.isLive = false
    }

    private func seed(reasoning item: String, summary: [String], content: [String]) {
        let joined = content.joined(separator: "\n")
        guard !summary.joined().isEmpty || !joined.isEmpty else { return }
        let row = liveReasoning(item)
        // the completed item is authoritative over whatever streamed
        if !summary.isEmpty {
            row.parts = summary.suffix(CodexReasoningRow.maxParts).map {
                $0.count > CodexReasoningRow.maxPartChars
                    ? String($0.prefix(CodexReasoningRow.maxPartChars)) : $0
            }
        }
        if !joined.isEmpty {
            row.raw = joined.count > CodexReasoningRow.maxRawChars
                ? String(joined.suffix(CodexReasoningRow.maxRawChars)) : joined
        }
        row.isLive = false
    }

    /// The row for this reasoning item, replacing the previous one. A turn can
    /// hold several reasoning items and only the newest is what "thinking"
    /// means.
    private func liveReasoning(_ item: String) -> CodexReasoningRow {
        if let row = reasoning, row.id == item { return row }
        let row = CodexReasoningRow(id: item)
        reasoning = row
        return row
    }

    private func reserve(part: Int, on row: CodexReasoningRow) {
        guard part >= 0, part < CodexReasoningRow.maxParts else { return }
        while row.parts.count <= part { row.parts.append("") }
    }

    // MARK: rows

    private func row(for item: CodexItem, kind: CodexActivityRow.Kind,
                     title: String, status: CodexWorkStatus) -> CodexActivityRow {
        if let existing = index[item.id] { return existing }
        let row = CodexActivityRow(id: item.id, kind: kind, turnId: item.turnId,
                                   title: title, status: status)
        rows.append(row)
        index[item.id] = row
        prune()
        return row
    }

    /// Drop the oldest *finished* rows once past the ceiling. What is running
    /// stays, however long the session has been going.
    private func prune() {
        guard rows.count > Self.maxRows else { return }
        var over = rows.count - Self.maxRows
        // never the row that was just added, however full the list is: the
        // caller is about to write into it
        let newest = rows.last
        rows.removeAll { row in
            guard over > 0, row.status != .inProgress, row !== newest else { return false }
            over -= 1
            index[row.id] = nil
            return true
        }
    }

    /// Equality-guarded, because Observation fires on a write of the same value
    /// and these are written on every re-send of an item.
    private func set<T: Equatable>(_ slot: inout T, _ value: T) {
        guard slot != value else { return }
        slot = value
    }

    // MARK: words

    private func elsewhere(_ cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard path != scope else { return nil }
        return "in \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    private static func title(for changes: [CodexFileEdit]) -> String {
        let names = changes.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        switch names.count {
        case 0: return "no files"
        case 1, 2: return names.joined(separator: ", ")
        default: return "\(names.count) files"
        }
    }

    private static func kinds(of changes: [CodexFileEdit]) -> String? {
        var tally: [CodexFileEdit.Kind: Int] = [:]
        for change in changes { tally[change.kind, default: 0] += 1 }
        let words = CodexFileEdit.Kind.allCases.compactMap { kind -> String? in
            guard let count = tally[kind] else { return nil }
            return "\(count) \(kind.word)"
        }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }
}
