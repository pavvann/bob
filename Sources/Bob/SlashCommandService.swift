import Foundation

/// One slash command the claude CLI will accept — `/ship`, `/vercel:deploy`.
struct SlashCommand: Identifiable, Equatable {
    enum Source: String { case builtIn = "built-in", user, project, plugin }
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
/// they manage an interactive REPL that doesn't exist inside bob's chat.
@MainActor
final class SlashCommandService: ObservableObject {
    static let shared = SlashCommandService()

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
    func matches(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return commands }
        let q = query.lowercased()
        var starts: [SlashCommand] = []
        var fuzzy: [SlashCommand] = []
        for cmd in commands {
            let n = cmd.name.lowercased()
            if n.hasPrefix(q) { starts.append(cmd) }
            else if isSubsequence(q, of: n) { fuzzy.append(cmd) }
        }
        return starts + fuzzy
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
        let userClaude = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        let projectClaude = root.appendingPathComponent(".claude")
        // The palette sends into bob's own session, so it may only offer what
        // that session can run. The companion's loadout drops the `user` settings
        // source (CompanionLoadout), which takes ~/.claude's skills and every
        // plugin's with it — offering `/ship` there would be offering a dead key.
        let carriesUserSkills = Self.companionCarriesUserSkills

        if carriesUserSkills {
            // user first, project after — project wins a name collision, like the CLI
            scanSkills(userClaude.appendingPathComponent("skills"), source: .user, into: &byName)
            scanCommands(userClaude.appendingPathComponent("commands"), source: .user, into: &byName)
        }
        scanSkills(projectClaude.appendingPathComponent("skills"), source: .project, into: &byName)
        scanCommands(projectClaude.appendingPathComponent("commands"), source: .project, into: &byName)
        // The harvest comes off a MINION's init event, and minions still carry the
        // whole machine — so when the companion doesn't, subtract by provenance:
        // what each source actually provides, named the way the CLI names it.
        let fromUser = carriesUserSkills ? [] : provided(in: userClaude)
        let fromProject = carriesUserSkills ? [] : provided(in: projectClaude)
        for name in harvestNames(root: root) where byName[name] == nil {
            if !carriesUserSkills, !reachable(name, fromProject: fromProject, fromUser: fromUser) {
                continue
            }
            byName[name] = SlashCommand(
                name: name, detail: "",
                source: name.contains(":") ? .plugin : .builtIn
            )
        }
        return byName.values
            .filter { !excluded($0.name) }
            .sorted { $0.name < $1.name }
    }

    /// Whether bob's companion still reads `~/.claude`'s settings — and so its
    /// skills and plugins. An empty source list is the CLI's default: everything.
    nonisolated static var companionCarriesUserSkills: Bool {
        let sources = CompanionLoadout.current.settingSources
        return sources.isEmpty || sources.contains("user")
    }

    /// Can bob's companion still run this harvested name once its loadout drops
    /// the `user` settings source?
    ///
    /// By provenance, not by shape. The `project` source is untouched, so whatever
    /// it provides stays — including a namespaced one: `~/bob/.claude/commands/
    /// team/deploy.md` is `/team:deploy` and runs fine. Judging the colon instead
    /// would have hidden it along with the plugins. What's left: a namespaced name
    /// the project doesn't claim belongs to a plugin (plugins are enabled *in*
    /// `~/.claude/settings.json`, so they left with it) or to a nested user
    /// command, and a plain name is one of the CLI's own built-ins unless
    /// `~/.claude` claims it.
    nonisolated private static func reachable(_ name: String,
                                             fromProject: Set<String>,
                                             fromUser: Set<String>) -> Bool {
        if fromProject.contains(name) { return true }
        if name.contains(":") { return false }
        return !fromUser.contains(name)
    }

    /// Every command name a `.claude` directory provides, named as the CLI names
    /// it. Scoped to its `skills/` and `commands/` children — the rest of
    /// `~/.claude` is transcripts and caches, and walking those would be both slow
    /// and wrong. Descriptions aren't read: this only ever builds a subtraction set.
    nonisolated private static func provided(in claudeDir: URL) -> Set<String> {
        skillNames(under: claudeDir.appendingPathComponent("skills"))
            .union(commandNames(under: claudeDir.appendingPathComponent("commands")))
    }

    /// The folder name of every `SKILL.md` below `dir`, at any depth — a skill is
    /// `/<its own folder>` however deep it sits, so `skills/gstack/ship/SKILL.md`
    /// is `/ship`, and a one-level scan would miss a whole suite of them.
    ///
    /// Recursion does NOT stop at a directory that is itself a skill: a skill dir
    /// can hold more skills (`gstack/` has its own `SKILL.md` *and* 46 beneath it),
    /// and stopping there was exactly the bug. Hidden directories are skipped —
    /// vendored copies live in `.slate/` and the CLI ignores them too.
    nonisolated private static func skillNames(under dir: URL, depth: Int = 0) -> Set<String> {
        guard depth < maxConfigDepth else { return [] }
        var out: Set<String> = []
        for item in contents(of: dir) where isDirectory(item) {
            if FileManager.default.fileExists(
                atPath: item.appendingPathComponent("SKILL.md").path) {
                out.insert(item.lastPathComponent)
            }
            out.formUnion(skillNames(under: item, depth: depth + 1))
        }
        return out
    }

    /// `<dir>/team/deploy.md` is `/team:deploy` — a command carries its
    /// subdirectories as its colon namespace, at any depth.
    nonisolated private static func commandNames(under dir: URL, prefix: String = "",
                                                 depth: Int = 0) -> Set<String> {
        guard depth < maxConfigDepth else { return [] }
        var out: Set<String> = []
        for item in contents(of: dir) {
            if isDirectory(item) {
                out.formUnion(commandNames(under: item,
                                           prefix: prefix + item.lastPathComponent + ":",
                                           depth: depth + 1))
            } else if item.pathExtension == "md" {
                out.insert(prefix + item.deletingPathExtension().lastPathComponent)
            }
        }
        return out
    }

    /// A config tree is shallow; six levels is generous and stops a symlink loop
    /// from walking forever.
    nonisolated private static let maxConfigDepth = 6

    nonisolated private static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
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
