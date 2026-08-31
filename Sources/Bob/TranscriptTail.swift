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
    enum Flavor: Sendable { case minionStream, cliTranscript, codexRollout }

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
        // Codex shares nothing with the claude dialect below but the clock: its
        // lines are `{ordinal, payload, timestamp, type}` and its `type` values
        // don't collide with claude's, so this is a fork rather than a set of
        // extra cases in one switch.
        if flavor == .codexRollout {
            ingestCodex(obj, into: &u)
            return
        }
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

    // MARK: - codex rollouts

    /// Codex's dialect. The feed lives in `event_msg/item_completed`, whose
    /// `item.type` is one of eleven shapes; `session_meta` (always line 0)
    /// carries the identity. Everything else on the wire — `response_item`,
    /// `token_count`, `world_state`, `turn_context` — is either a duplicate of
    /// an item or state this feed doesn't render.
    private static func ingestCodex(_ obj: [String: Any], into u: inout Update) {
        guard let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }
        switch type {
        case "session_meta":
            if let c = payload["cwd"] as? String, !c.isEmpty { u.cwd = c }
            // branch comes free here — the claude path has to shell out for it
            if let git = payload["git"] as? [String: Any],
               let b = git["branch"] as? String, !b.isEmpty { u.gitBranch = b }
            if let m = CodexProbe.model(from: payload) { u.model = m }
        case "event_msg":
            guard (payload["type"] as? String) == "item_completed",
                  let item = payload["item"] as? [String: Any] else { return }
            appendCodexItem(item, into: &u)
        default:
            break
        }
    }

    private static func appendCodexItem(_ item: [String: Any], into u: inout Update) {
        switch item["type"] as? String {
        case "UserMessage":
            if let t = clean(codexText(item["content"]), limit: 280) {
                u.events.append(FeedEvent(kind: .prompt, symbol: "person.fill", text: t))
            }
        case "AgentMessage":
            if let t = clean(codexText(item["content"]), limit: 280) {
                u.events.append(FeedEvent(kind: .thought, symbol: "bubble.left", text: t))
            }
        case "Reasoning":
            // The most common item by a wide margin, and usually empty — the
            // summary is filled in only when the model published one. Emitting
            // the blanks would bury every row that says something.
            if let t = clean(codexFirstText(item["summary_text"]), limit: 280) {
                u.events.append(FeedEvent(kind: .thought, symbol: "brain", text: t))
            }
        case "CommandExecution":
            u.events.append(FeedEvent(kind: .action, symbol: "terminal",
                                      text: "running \(String(codexCommand(item).prefix(80)))"))
            if let out = clean(codexOutput(item), limit: 160) {
                u.events.append(FeedEvent(kind: .output, symbol: "arrow.turn.down.right", text: out))
            }
        case "FileChange":
            if let row = codexFileChange(item) { u.events.append(row) }
        case "Extension":
            // codex's tool-call row. `kind` is the tool identity ("web.search")
            // — the analog of an mcp__server__tool name on the claude side.
            u.events.append(FeedEvent(kind: .action, symbol: "gearshape",
                                      text: (item["kind"] as? String) ?? "extension"))
        case "SubAgentActivity":
            let what = (item["kind"] as? String) ?? "working"
            let who = (item["agent_path"] as? String)
                .map { " \(($0 as NSString).lastPathComponent)" } ?? ""
            u.events.append(FeedEvent(kind: .action, symbol: "person.2",
                                      text: "sub-agent \(what)\(who)"))
        case "CollabAgentToolCall":
            u.events.append(FeedEvent(kind: .action, symbol: "person.2",
                                      text: "agents: \((item["tool"] as? String) ?? "call")"))
        case "ContextCompaction":
            u.events.append(FeedEvent(kind: .output, symbol: "arrow.down.right.and.arrow.up.left",
                                      text: "context compacted"))
        case "EnteredReviewMode":
            u.events.append(FeedEvent(kind: .action, symbol: "checkmark.seal",
                                      text: "reviewing \((item["user_facing_hint"] as? String) ?? "changes")"))
        case "ExitedReviewMode":
            let n = ((item["review_output"] as? [String: Any])?["findings"] as? [[String: Any]])?.count ?? 0
            u.events.append(FeedEvent(kind: .output, symbol: "checkmark.seal",
                                      text: n == 1 ? "review: 1 finding" : "review: \(n) findings"))
        default:
            break
        }
    }

    /// Message content is `[{type, text}]` — and the case of `type` differs by
    /// item: `UserMessage` writes `text`, `AgentMessage` writes `Text`. Folding
    /// the case is cheaper than tracking which item said which.
    static func codexText(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return content as? String }
        for block in blocks where (block["type"] as? String)?.lowercased() == "text" {
            if let t = block["text"] as? String, !t.isEmpty { return t }
        }
        return nil
    }

    /// `summary_text` is an array of either bare strings or `{text:}` objects
    /// depending on how the summary was produced.
    private static func codexFirstText(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        guard let list = any as? [Any] else { return nil }
        for v in list {
            if let s = v as? String, !s.isEmpty { return s }
            if let d = v as? [String: Any], let s = d["text"] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// `command` is argv — `["/bin/zsh", "-lc", "<the actual thing>"]` — so the
    /// last element is what a human would recognize. `parsed_cmd` is codex's own
    /// cleaned form and wins when it's there.
    private static func codexCommand(_ item: [String: Any]) -> String {
        if let parsed = item["parsed_cmd"] as? [[String: Any]],
           let cmd = parsed.compactMap({ $0["cmd"] as? String }).first(where: { !$0.isEmpty }) {
            return codexFirstLine(cmd)
        }
        if let argv = item["command"] as? [String], let last = argv.last, !last.isEmpty {
            return codexFirstLine(last)
        }
        if let s = item["command"] as? String, !s.isEmpty { return codexFirstLine(s) }
        return "a command"
    }

    private static func codexFirstLine(_ s: String) -> String {
        s.split(separator: "\n").first.map(String.init) ?? s
    }

    private static func codexOutput(_ item: [String: Any]) -> String? {
        for key in ["aggregated_output", "stdout", "stderr"] {
            if let s = item[key] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
        }
        return nil
    }

    /// `changes` is keyed by absolute path and its values carry whole file
    /// contents — which is why only the keys are ever read here.
    private static func codexFileChange(_ item: [String: Any]) -> FeedEvent? {
        guard let changes = item["changes"] as? [String: Any], !changes.isEmpty else { return nil }
        let paths = changes.keys.sorted()
        let verb: String
        switch (changes[paths[0]] as? [String: Any])?["type"] as? String {
        case "add":    verb = "adding"
        case "delete": verb = "deleting"
        default:       verb = "editing"
        }
        let name = (paths[0] as NSString).lastPathComponent
        let more = paths.count > 1 ? " +\(paths.count - 1)" : ""
        return FeedEvent(kind: .action, symbol: "pencil", text: "\(verb) \(name)\(more)")
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

/// The identity check on a codex rollout: who started it, whether a human is
/// sitting in front of it, where it runs, and when it last actually spoke.
/// Reads a bounded head + tail — the rollouts reach tens of megabytes.
struct CodexProbe: Sendable {
    /// `codex-tui` (a terminal), `codex_exec` (`codex exec`), `bob` /
    /// `bob-probe` (bob's own hands). The analog of claude's `entrypoint`.
    var originator: String?
    /// True only when `source` is the literal string `"cli"`. A subagent thread
    /// spawned by a tui session carries the same `originator` but an object
    /// (`{subagent: {…}}`) here, and must not earn a card of its own.
    var isInteractive = false
    var threadId: String?
    var cwd: String?
    var gitBranch: String?
    var model: String?
    /// The human's opening words, when they fall inside the bounded read.
    var fallbackTitle: String?
    /// The agent's most recent word — the second-choice title, see `title`.
    var lastAgentText: String?
    /// Newest real event in the file — the liveness clock.
    var lastEventAt: Date?
    /// At least one completed item: proof this is a session and not a stub.
    var hasActivity = false

    /// What a card calls this session. Codex writes no equivalent of claude's
    /// `ai-title`, so the human's own words are first choice — but `session_meta`
    /// eats most of the bounded head (up to 22KB of base instructions), so on a
    /// long session the opening prompt lands in neither the head nor the tail.
    /// Measured against the rollouts on this machine, two sessions in three had
    /// no reachable user message. The agent's latest word is the honest fallback:
    /// it is at least a sentence about what this session is doing.
    var title: String? { fallbackTitle ?? lastAgentText }

    /// `headBytes` has to clear line 0 whole, because `session_meta` carries the
    /// full base instructions: measured across every rollout on this machine it
    /// runs 265B to 22KB, so 32KB is the floor that keeps identity readable.
    static func probe(_ url: URL, headBytes: Int = 32_768, tailBytes: UInt64 = 65_536) -> CodexProbe? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var p = CodexProbe()
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        p.ingest(chunk: head, dropFirstPartial: false, dropLastPartial: true)
        // identity is settled by line 0; anything that isn't a terminal session
        // is dropped before the tail read, which is the expensive half
        guard p.originator != nil, p.isInteractive else { return nil }
        if let size = try? handle.seekToEnd(), size > UInt64(headBytes) {
            let start = max(UInt64(headBytes), size > tailBytes ? size - tailBytes : 0)
            try? handle.seek(toOffset: start)
            let tail = handle.readDataToEndOfFile()
            p.ingest(chunk: tail, dropFirstPartial: true, dropLastPartial: false)
        }
        guard p.hasActivity else { return nil }
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
        guard let type = obj["type"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }
        switch type {
        case "session_meta":
            originator = payload["originator"] as? String
            isInteractive = (payload["source"] as? String) == "cli"
            threadId = (payload["session_id"] as? String) ?? (payload["id"] as? String)
            if let c = payload["cwd"] as? String, !c.isEmpty { cwd = c }
            if let git = payload["git"] as? [String: Any],
               let b = git["branch"] as? String, !b.isEmpty { gitBranch = b }
            model = Self.model(from: payload)
        case "event_msg":
            guard (payload["type"] as? String) == "item_completed",
                  let item = payload["item"] as? [String: Any] else { return }
            hasActivity = true
            switch item["type"] as? String {
            case "UserMessage":
                if fallbackTitle == nil, let t = TranscriptParser.codexText(item["content"]) {
                    fallbackTitle = Self.clip(t)
                }
            case "AgentMessage":
                if let t = TranscriptParser.codexText(item["content"]) { lastAgentText = Self.clip(t) }
            default:
                break
            }
        default:
            break
        }
    }

    private static func clip(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    /// `base_instructions.provenance.model` is where a session records the
    /// resolved model; the flat `model` and `state.model` are other shapes of
    /// the same line. First one that answers wins.
    static func model(from payload: [String: Any]) -> String? {
        if let bi = payload["base_instructions"] as? [String: Any],
           let prov = bi["provenance"] as? [String: Any],
           let m = prov["model"] as? String, !m.isEmpty { return m }
        if let m = payload["model"] as? String, !m.isEmpty { return m }
        if let state = payload["state"] as? [String: Any],
           let m = state["model"] as? String, !m.isEmpty { return m }
        return nil
    }
}
