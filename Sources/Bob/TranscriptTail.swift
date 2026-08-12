import Foundation

/// One rendered moment in a session's feed — a prompt typed, a thought voiced,
/// a tool reached for, or what the tool said back. Shared by minion panels
/// (claude stream-json) and external session panels (claude code transcripts).
struct FeedEvent: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case prompt, thought, action, output }
    let id = UUID()
    let kind: Kind
    let symbol: String   // SF Symbol
    let text: String
}

/// The closing numbers of a finished run — emitted by minion stream-json only.
struct FeedFinal: Equatable, Sendable {
    var resultText: String?
    var durationMs: Int?
    var costUSD: Double?
    var numTurns: Int?
    var isError = false
}

/// Incremental line reader for an append-only jsonl file. Keeps a byte offset,
/// hands back only complete new lines, never re-reads the whole file: the
/// first read starts from a bounded tail, and a half-written trailing line
/// waits for the next poll instead of being consumed and lost.
struct TranscriptTailer: Sendable {
    var url: URL
    private var offset: UInt64 = 0
    private var primed = false

    init(url: URL) { self.url = url }

    mutating func readNewLines(bootstrapBytes: UInt64 = 262_144) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        var skippedIn = false
        if !primed || end < offset {
            // first read — or the file shrank under us — start from a bounded tail
            offset = end > bootstrapBytes ? end - bootstrapBytes : 0
            skippedIn = offset > 0
            primed = true
        }
        guard end > offset, (try? handle.seek(toOffset: offset)) != nil else { return [] }
        let data = handle.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
        var consumable = data[...lastNewline]
        offset += UInt64(consumable.count)
        if skippedIn, let firstNewline = consumable.firstIndex(of: 0x0A) {
            // we landed mid-line — the first fragment isn't parseable
            consumable = consumable[consumable.index(after: firstNewline)...]
        }
        guard let text = String(data: Data(consumable), encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// The honest clock on a transcript. Real conversation events carry an
/// ISO-8601 `timestamp`; the heartbeat lines claude upserts in place
/// (`bridge-session`, `mode`, `last-prompt`, `ai-title`, `file-history-snapshot`)
/// carry none. So a fleet-wide config sync can touch an idle transcript's mtime
/// without moving this — which is the whole point: mtime lies, this doesn't.
enum EventClock {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

    /// The line's own event time, or nil for the untimestamped heartbeat lines.
    static func stamp(_ obj: [String: Any]) -> Date? {
        guard let s = obj["timestamp"] as? String, !s.isEmpty else { return nil }
        return fractional.date(from: s) ?? whole.date(from: s)
    }

    static func advance(_ latest: inout Date?, with obj: [String: Any]) {
        guard let at = stamp(obj) else { return }
        if latest == nil || at > latest! { latest = at }
    }
}

/// Turns raw jsonl lines into feed events. Two dialects share one parser:
/// minion stream-json (`claude -p --output-format stream-json`) and the
/// transcripts claude code writes under `~/.claude/projects/`. Every branch
/// is defensive — unknown or half-written lines are skipped, never fatal.
enum TranscriptParser {
    enum Flavor: Sendable { case minionStream, cliTranscript }

    struct Update: Sendable {
        var events: [FeedEvent] = []
        var title: String?
        var cwd: String?
        var gitBranch: String?
        var model: String?
        var final: FeedFinal?
        /// Newest real event time seen in these lines — the liveness clock.
        var lastEventAt: Date?
    }

    static func parse(lines: [String], flavor: Flavor) -> Update {
        var update = Update()
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            ingest(obj, flavor: flavor, into: &update)
        }
        return update
    }

    static func ingest(_ obj: [String: Any], flavor: Flavor, into u: inout Update) {
        EventClock.advance(&u.lastEventAt, with: obj)
        if let c = obj["cwd"] as? String, !c.isEmpty { u.cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { u.gitBranch = b }
        guard let type = obj["type"] as? String else { return }
        guard (obj["isSidechain"] as? Bool) != true else { return }

        switch type {
        case "assistant":
            guard (obj["isMeta"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any] else { return }
            if let m = message["model"] as? String { u.model = m }
            for block in (message["content"] as? [[String: Any]]) ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = clean(block["text"] as? String, limit: 280) {
                        u.events.append(FeedEvent(kind: .thought, symbol: "bubble.left", text: t))
                    }
                case "thinking":
                    if let t = clean(block["thinking"] as? String, limit: 280) {
                        u.events.append(FeedEvent(kind: .thought, symbol: "brain", text: t))
                    }
                case "tool_use":
                    if let name = block["name"] as? String {
                        u.events.append(humanizeTool(name: name, input: block["input"] as? [String: Any] ?? [:]))
                    }
                default:
                    break
                }
            }
        case "user":
            guard (obj["isMeta"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any] else { return }
            if let text = message["content"] as? String {
                if let t = clean(text, limit: 280) {
                    u.events.append(FeedEvent(kind: .prompt, symbol: "person.fill", text: t))
                }
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = clean(block["text"] as? String, limit: 280) {
                            u.events.append(FeedEvent(kind: .prompt, symbol: "person.fill", text: t))
                        }
                    case "tool_result":
                        if let t = clean(flattened(block["content"]), limit: 160) {
                            u.events.append(FeedEvent(kind: .output, symbol: "arrow.turn.down.right", text: t))
                        }
                    default:
                        break
                    }
                }
            }
        case "system":
            if (obj["subtype"] as? String) == "init", let m = obj["model"] as? String { u.model = m }
        case "result" where flavor == .minionStream:
            var final = FeedFinal(isError: (obj["is_error"] as? Bool) ?? false)
            final.resultText = clean(obj["result"] as? String, limit: 700, firstLineOnly: false)
            final.durationMs = obj["duration_ms"] as? Int
            final.costUSD = obj["total_cost_usd"] as? Double
            final.numTurns = obj["num_turns"] as? Int
            u.final = final
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty { u.title = t }
        case "summary":
            if u.title == nil, let t = obj["summary"] as? String, !t.isEmpty { u.title = t }
        default:
            break
        }
    }

    private static func clean(_ s: String?, limit: Int, firstLineOnly: Bool = true) -> String? {
        guard let s else { return nil }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // interface chrome, not conversation: injected tags, caveats, interrupts
        if t.hasPrefix("<") || t.hasPrefix("Caveat:") || t.hasPrefix("[Request interrupted") { return nil }
        if firstLineOnly, let first = t.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            t = first.trimmingCharacters(in: .whitespaces)
        }
        return String(t.prefix(limit))
    }

    private static func flattened(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { return t }
            }
        }
        return nil
    }

    private static func humanizeTool(name: String, input: [String: Any]) -> FeedEvent {
        func base(_ key: String) -> String {
            guard let p = input[key] as? String, !p.isEmpty else { return "" }
            return (p as NSString).lastPathComponent
        }
        switch name {
        case "Read":
            return FeedEvent(kind: .action, symbol: "doc.text", text: "reading \(base("file_path"))")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return FeedEvent(kind: .action, symbol: "pencil", text: "editing \(base("file_path"))")
        case "Bash":
            let raw = (input["command"] as? String) ?? ""
            let cmd = raw.split(separator: "\n").first.map(String.init) ?? raw
            return FeedEvent(kind: .action, symbol: "terminal", text: "running \(String(cmd.prefix(80)))")
        case "Grep":
            return FeedEvent(kind: .action, symbol: "magnifyingglass", text: "searching \((input["pattern"] as? String) ?? "")")
        case "Glob":
            return FeedEvent(kind: .action, symbol: "folder", text: "globbing \((input["pattern"] as? String) ?? "")")
        case "WebSearch":
            return FeedEvent(kind: .action, symbol: "globe", text: "searching web: \((input["query"] as? String) ?? "")")
        case "WebFetch":
            let raw = (input["url"] as? String) ?? ""
            return FeedEvent(kind: .action, symbol: "globe", text: "fetching \(URL(string: raw)?.host ?? raw)")
        case "Task", "Agent":
            let desc = (input["description"] as? String) ?? "a sub-agent"
            return FeedEvent(kind: .action, symbol: "person.2", text: "delegating: \(desc)")
        case "ToolSearch":
            return FeedEvent(kind: .action, symbol: "wrench.and.screwdriver", text: "looking up tools")
        case "Skill":
            let skill = (input["skill"] as? String) ?? (input["command"] as? String) ?? "a skill"
            return FeedEvent(kind: .action, symbol: "wand.and.stars", text: "using \(skill)")
        case "TodoWrite":
            return FeedEvent(kind: .action, symbol: "checklist", text: "updating the plan")
        case "AskUserQuestion":
            return FeedEvent(kind: .action, symbol: "questionmark.bubble", text: "asking a question")
        case "ExitPlanMode":
            return FeedEvent(kind: .action, symbol: "map", text: "presenting the plan")
        default:
            return FeedEvent(kind: .action, symbol: "gearshape", text: name.lowercased())
        }
    }
}

/// A cheap identity check on a transcript: who started it (terminal `cli` vs
/// bob's own spawns `sdk-cli`), where it runs, and what to call it. Reads a
/// bounded head + tail of the file — never the whole thing.
struct SessionProbe: Sendable {
    var entrypoint: String?
    var cwd: String?
    var gitBranch: String?
    var title: String?
    var fallbackTitle: String?
    var hasConversation = false
    /// Newest real event time in the file — fresh only if the session actually
    /// spoke, not merely if claude rewrote the file's metadata underneath it.
    var lastEventAt: Date?

    static func probe(_ url: URL, headBytes: Int = 49_152, tailBytes: UInt64 = 65_536) -> SessionProbe? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var p = SessionProbe()
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        p.ingest(chunk: head, dropFirstPartial: false, dropLastPartial: true)
        if let size = try? handle.seekToEnd(), size > UInt64(headBytes) {
            let start = max(UInt64(headBytes), size > tailBytes ? size - tailBytes : 0)
            try? handle.seek(toOffset: start)
            let tail = handle.readDataToEndOfFile()
            p.ingest(chunk: tail, dropFirstPartial: true, dropLastPartial: false)
        }
        guard p.hasConversation else { return nil }
        return p
    }

    private mutating func ingest(chunk: Data, dropFirstPartial: Bool, dropLastPartial: Bool) {
        var data = chunk[...]
        if dropLastPartial {
            guard let last = data.lastIndex(of: 0x0A) else { return }
            data = data[...last]
        }
        if dropFirstPartial {
            guard let first = data.firstIndex(of: 0x0A) else { return }
            data = data[data.index(after: first)...]
        }
        guard let text = String(data: Data(data), encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            else { continue }
            ingest(line: obj)
        }
    }

    private mutating func ingest(line obj: [String: Any]) {
        EventClock.advance(&lastEventAt, with: obj)
        if entrypoint == nil, let ep = obj["entrypoint"] as? String { entrypoint = ep }
        if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
        if let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "ai-title":
            if let t = obj["aiTitle"] as? String, !t.isEmpty { title = t }
        case "summary":
            if title == nil, let t = obj["summary"] as? String, !t.isEmpty { title = t }
        case "user":
            guard (obj["isMeta"] as? Bool) != true, (obj["isSidechain"] as? Bool) != true else { return }
            hasConversation = true
            if fallbackTitle == nil,
               let message = obj["message"] as? [String: Any],
               let text = message["content"] as? String {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") {
                    let first = t.split(separator: "\n").first.map(String.init) ?? t
                    fallbackTitle = String(first.prefix(80))
                }
            }
        case "assistant":
            if (obj["isSidechain"] as? Bool) != true { hasConversation = true }
        default:
            break
        }
    }
}
