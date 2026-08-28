import Foundation

/// One slash command the claude CLI will accept — `/ship`, `/vercel:deploy` —
/// or one bob implements itself.
struct SlashCommand: Identifiable, Equatable {
    enum Source: String { case bob, builtIn = "built-in", user, project, plugin }
    let name: String
    /// One-line description where the filesystem has one; "" for CLI-only names.
    let detail: String
    let source: Source
    var id: String { name }
}

/// Discovers the slash commands claude accepts from ~/bob, for the input bar's
/// `/` palette. Verified against the real CLI: `claude -p "/cmd args"` expands
/// and runs the command ($ARGUMENTS included), on `--session-id` first turns
/// and `--resume` turns alike — so bob only has to complete the name and send
/// the message untouched.
///
/// Two sources, merged:
///  - the filesystem — `~/.claude/{skills,commands}` (user) and
///    `~/bob/.claude/{skills,commands}` (project). Instant, and the only place
///    one-line descriptions live (SKILL.md / command frontmatter).
///  - the CLI itself — every minion run emits a stream-json `init` event whose
///    `slash_commands` array is the authoritative list for cwd ~/bob, adding
///    built-ins and plugin commands (`vercel:deploy`) no scan can see. The
///    newest harvest is cached in `~/bob/state/slash-commands.json` so the
///    palette is complete from launch without ever spawning claude for it.
///
/// Terminal-session built-ins (/clear, /model, /usage...) are curated out —
/// they manage an interactive REPL that doesn't exist inside bob's chat. The two
/// bob reimplements as its own gestures come back through `native`, because the
/// curation is by name and would otherwise take them with it.
@MainActor
final class SlashCommandService: ObservableObject {
    static let shared = SlashCommandService()

    /// Which input bar is asking. The list is not the same on all three: this
    /// one holds claude's commands, and claude's commands are meaningless to
    /// codex — app-server's `turn/start` takes text, a `/name` inside text stays
    /// text, and there is no expansion RPC and no command catalogue to expand
    /// from. Offering them on a codex tab would be 150-odd rows that all quietly
    /// do nothing, which is worse than an empty palette.
    enum Scope: Equatable {
        /// bob's own thread.
        case companion
        /// A work tab. Claude's expand in-session; codex's don't exist.
        case work(SessionProvider)
    }

    @Published private(set) var commands: [SlashCommand] = []

    private let root: URL
    private var lastRefresh: Date = .distantPast

    private init() {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob", isDirectory: true)
        refresh(force: true)
    }

    /// Commands matching what's typed after the `/`. Prefix matches lead,
    /// subsequence matches trail; both case-insensitive. "" matches everything.
    /// bob's own commands lead their match class — there are two of them, and a
    /// fuzzy match against 150 names would otherwise bury both.
    func matches(_ query: String, in scope: Scope) -> [SlashCommand] {
        let pool = Self.native(in: scope) + (Self.runsClaudeCommands(scope) ? commands : [])
        guard !query.isEmpty else { return pool }
        let q = query.lowercased()
        var starts: [SlashCommand] = []
        var fuzzy: [SlashCommand] = []
        for cmd in pool {
            let n = cmd.name.lowercased()
            if n.hasPrefix(q) { starts.append(cmd) }
            else if isSubsequence(q, of: n) { fuzzy.append(cmd) }
        }
        return starts + fuzzy
    }

    /// Whether the surface can actually run a claude CLI command.
    private static func runsClaudeCommands(_ scope: Scope) -> Bool {
        switch scope {
        case .companion:            return true
        case .work(let provider):   return provider == .claude
        }
    }

    /// The commands bob implements itself — intercepted in the input bar and
    /// never sent anywhere. They are listed rather than left to be remembered:
    /// `/resume` reads as broken when the palette goes blank as you finish
    /// typing it, which is exactly what a name in `terminalOnly` does.
    ///
    /// `/model` is the companion's alone. A work tab's model is picked in the
    /// "+" picker (claude) or the stage dial (codex), and bob would have nothing
    /// to switch.
    private static func native(in scope: Scope) -> [SlashCommand] {
        var out = [SlashCommand(
            name: "resume",
            detail: "pick up a conversation this project already has",
            source: .bob
        )]
        if scope == .companion {
            out.append(SlashCommand(
                name: "model",
                detail: "which model bob runs on — /model opus·sonnet·haiku·fable·default",
                source: .bob
            ))
        }
        return out
    }

    /// Rebuild the list off the main thread. Throttled — the palette calls this
    /// on every open, and a fresh harvest only happens when a newer minion
    /// events file has appeared since the cache was written.
    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = Date()
        let root = self.root
        Task.detached(priority: .utility) {
            let assembled = Self.assemble(root: root)
            await MainActor.run { self.commands = assembled }
        }
    }

    // MARK: assembly (background)

    nonisolated private static func assemble(root: URL) -> [SlashCommand] {
        var byName: [String: SlashCommand] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser
        // user first, project after — project wins a name collision, like the CLI
        scanSkills(home.appendingPathComponent(".claude/skills"), source: .user, into: &byName)
        scanCommands(home.appendingPathComponent(".claude/commands"), source: .user, into: &byName)
        scanSkills(root.appendingPathComponent(".claude/skills"), source: .project, into: &byName)
        scanCommands(root.appendingPathComponent(".claude/commands"), source: .project, into: &byName)
        for name in harvestNames(root: root) where byName[name] == nil {
            byName[name] = SlashCommand(
                name: name, detail: "",
                source: name.contains(":") ? .plugin : .builtIn
            )
        }
        return byName.values
            .filter { !excluded($0.name) }
            .sorted { $0.name < $1.name }
    }

    /// `<dir>/<name>/SKILL.md` — skills invokable as `/name`.
    nonisolated private static func scanSkills(
        _ dir: URL, source: SlashCommand.Source, into byName: inout [String: SlashCommand]
    ) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let skill = item.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skill.path) else { continue }
            let name = item.lastPathComponent
            byName[name] = SlashCommand(name: name, detail: oneLiner(of: skill), source: source)
        }
    }

    /// `<dir>/<name>.md` — classic prompt-template commands.
    nonisolated private static func scanCommands(
        _ dir: URL, source: SlashCommand.Source, into byName: inout [String: SlashCommand]
    ) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for item in items where item.pathExtension == "md" {
            let name = item.deletingPathExtension().lastPathComponent
            byName[name] = SlashCommand(name: name, detail: oneLiner(of: item), source: source)
        }
    }

    /// First line of the frontmatter `description:` (inline or block scalar) —
    /// or, without frontmatter, the first non-empty line of the body.
    nonisolated private static func oneLiner(of url: URL) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = Array(raw.components(separatedBy: "\n").prefix(80))
        var body = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" { i += 1 }
            if let desc = frontmatterDescription(Array(lines[1..<min(i, lines.count)])) { return desc }
            body = min(i + 1, lines.count)
        }
        for line in lines[body...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        }
        return ""
    }

    nonisolated private static func frontmatterDescription(_ front: [String]) -> String? {
        for (j, line) in front.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("description:") else { continue }
            var value = String(t.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "|" || value == ">" || value == "|-" || value == ">-" {
                for next in front[(j + 1)...] {
                    let n = next.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { value = n; break }
                }
            }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: CLI harvest

    private struct Cache: Codable {
        var sourcePath: String
        var sourceMtime: Double
        var names: [String]
    }

    /// Authoritative names from the newest minion `init` event, cached to
    /// `state/slash-commands.json`. Falls back to the cache (then to nothing)
    /// when no events file yields a list — the filesystem scan still stands.
    nonisolated private static func harvestNames(root: URL) -> [String] {
        let fm = FileManager.default
        let cacheURL = root.appendingPathComponent("state/slash-commands.json")
        let cached = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }

        var candidates: [(url: URL, mtime: Double)] = []
        for sub in ["minions", "minions/done", "minions/failed"] {
            let dir = root.appendingPathComponent(sub)
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items where url.lastPathComponent.hasSuffix(".events.jsonl") {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                candidates.append((url, m))
            }
        }
        candidates.sort { $0.mtime > $1.mtime }

        // nothing newer than what the cache was harvested from — reuse it
        if let cached,
           candidates.first.map({ $0.url.path == cached.sourcePath && $0.mtime == cached.sourceMtime }) ?? true {
            return cached.names
        }
        for c in candidates.prefix(8) {
            guard let names = initSlashCommands(in: c.url) else { continue }
            let cache = Cache(sourcePath: c.url.path, sourceMtime: c.mtime, names: names)
            try? fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL) }
            return names
        }
        return cached?.names ?? []
    }

    /// The `system/init` event sits near the top of an events file (hooks can
    /// precede it) — scan the first chunk only, never the whole transcript.
    nonisolated private static func initSlashCommands(in url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(300) {
            guard line.contains("\"slash_commands\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "system",
                  obj["subtype"] as? String == "init",
                  let names = obj["slash_commands"] as? [String]
            else { continue }
            return names
        }
        return nil
    }

    // MARK: curation

    nonisolated private static func excluded(_ name: String) -> Bool {
        name.hasPrefix("_") || name.contains("mcp__") || terminalOnly.contains(name)
    }

    /// Interactive-REPL housekeeping — session, account and terminal-UI
    /// commands that are meaningless (or misleading) inside a `-p` chat.
    nonisolated private static let terminalOnly: Set<String> = [
        "add-dir", "agents", "autocompact", "bashes", "bug", "clear", "color",
        "compact", "config", "context", "cost", "doctor", "effort", "exit",
        "export", "extra-usage", "fast", "goal", "heapdump", "help", "hooks",
        "ide", "import", "init", "insights", "install-github-app", "list-agents",
        "login", "logout", "mcp", "memory", "model", "output-style",
        "permissions", "privacy-settings", "quit", "recap", "release-notes",
        "reload-skills", "rename", "resume", "run-skill-generator", "status",
        "statusline", "team-onboarding", "terminal-setup", "todos", "upgrade",
        "usage", "usage-credits", "vim", "workflow-launch-exec",
    ]

    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var i = needle.startIndex
        for ch in haystack {
            if i == needle.endIndex { return true }
            if ch == needle[i] { i = needle.index(after: i) }
        }
        return i == needle.endIndex
    }
}
