import Foundation

/// How much of a coding terminal's kit bob's companion carries.
///
/// Every `claude` bob spawns inherits the whole machine: the user's ~94 skills
/// in `~/.claude/skills`, every enabled plugin and the MCP servers it brings,
/// every globally configured MCP server, all 30-odd built-in tools. Measured
/// against `--model sonnet` in `~/bob` (2026-08-19, CLI 2.1.235), that is
/// **53,573 tokens of prompt before a word is typed** — 27% of a 200k window,
/// most of it a loadout a chat companion never opens.
///
/// The itemized bill, each row measured by removing exactly that one thing:
///
/// | contributor                                        | tokens |
/// | -------------------------------------------------- | -----: |
/// | the CLI's own base prompt (no tools, no cwd)        |  9,024 |
/// | the built-in tools the companion keeps (11 of them) | 13,543 |
/// | cwd `~/bob` — bob's CLAUDE.md, its skills, git      |  6,835 |
/// | `~/.claude/skills` + 5 plugins (skills, MCP, agents)|  9,356 |
/// | 48 built-in + project skills still reachable        |  2,682 |
/// | 9 globally configured MCP servers' tool listings    |  2,277 |
///
/// So the companion drops the last two groups it doesn't use and trims the
/// built-ins to what bob's operating manual actually asks for — 53,573 →
/// ~32,000, and every number above stays visible in
/// `~/bob/state/companion-loadout.json`, which the owner can edit.
///
/// **Work sessions are never slimmed.** A tab in `~/Code/whatever` must be the
/// same claude the owner gets in a terminal — same skills, same plugins, same
/// MCP — or bob stops being a window onto his own setup. Minions are slimmed
/// only of MCP servers: a headless worker can't complete an OAuth flow anyway,
/// but it *can* need `/git-guardrail` before it commits, so its skills stay.
struct CompanionLoadout: Decodable, Equatable {
    /// Hand the CLI an empty MCP config and tell it to ignore every other one
    /// (`--strict-mcp-config`). Verified: no file in bob calls an MCP tool, and
    /// SlashCommandService already filters `mcp__*` out of the `/` palette.
    var dropGlobalMCPServers: Bool = true

    /// Which of the CLI's settings files the companion reads. Dropping `user`
    /// drops `~/.claude/settings.json` — with it the ~94 skills under
    /// `~/.claude/skills`, the five enabled plugins (vercel, figma, three LSPs)
    /// and everything they carry, and the terminal-shaped global hooks. `~/bob`'s
    /// own `.claude/` still loads, so bob's own skills survive.
    /// An empty list means "every source", i.e. today's terminal behaviour.
    var settingSources: [String] = ["project", "local"]

    /// The built-in tools the companion is allowed to see. Each one costs its
    /// schema in every single turn, so this is the list bob's CLAUDE.md actually
    /// asks for and nothing else. Marginal costs, measured one add at a time:
    /// Read 1,260 · Edit 579 · Write 360 · Bash 4,118 · AskUserQuestion 1,389 ·
    /// WebSearch 659 · WebFetch 699 · Task 3,634 · TaskOutput 543 · TaskStop 302.
    /// An empty list means "every built-in tool".
    ///
    /// Cut, and why: Cron*/ScheduleWakeup/RemoteTrigger/Workflow/PushNotification
    /// (bob's minions and its own clock do this), EnterPlanMode/ExitPlanMode and
    /// Enter/ExitWorktree (a chat has no plan mode and no worktree), NotebookEdit
    /// and LSP (bob edits markdown), DesignSync/ShareOnboardingGuide/ReportFindings/
    /// ListAgents/Monitor (unused), ToolSearch and the three McpResource tools
    /// (nothing to search once the MCP servers are gone).
    var tools: [String] = [
        "Read", "Edit", "Write",        // the wiki, notes, canvas, state/todos.json
        "Bash",                         // `open -a`, osascript, say, gh — CLAUDE.md's "what you can do"
        "AskUserQuestion",              // bob's question cards (SessionQuestion)
        "WebSearch", "WebFetch",        // a chat companion looks things up
        "Task", "TaskOutput", "TaskStop", // the agents rail; CLAUDE.md documents the Agent tool
        "Skill",                        // the `/` palette sends slash commands here
    ]

    /// Minions get the same MCP treatment (a background worker can't finish an
    /// OAuth handshake), worth ~2,200 tokens a run.
    var minionsDropGlobalMCPServers: Bool = true

    /// Minions deliberately keep the full skill set — `/git-guardrail` before a
    /// commit, `/review` before a PR. Trim this to `["project", "local"]` to buy
    /// back ~9,400 tokens a run at the cost of those.
    var minionsSettingSources: [String] = ["user", "project", "local"]

    init() {}

    /// Key by key, each one falling back to bob's default — so deleting a line
    /// from the file really does mean "use bob's answer for that one" and doesn't
    /// throw away the four edits either side of it. The synthesized decoder would
    /// demand all five keys and fail the whole file over a missing one.
    private enum Key: String, CodingKey {
        case dropGlobalMCPServers, settingSources, tools
        case minionsDropGlobalMCPServers, minionsSettingSources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let d = CompanionLoadout()
        dropGlobalMCPServers =
            try c.decodeIfPresent(Bool.self, forKey: .dropGlobalMCPServers) ?? d.dropGlobalMCPServers
        settingSources =
            try c.decodeIfPresent([String].self, forKey: .settingSources) ?? d.settingSources
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? d.tools
        minionsDropGlobalMCPServers =
            try c.decodeIfPresent(Bool.self, forKey: .minionsDropGlobalMCPServers)
            ?? d.minionsDropGlobalMCPServers
        minionsSettingSources =
            try c.decodeIfPresent([String].self, forKey: .minionsSettingSources)
            ?? d.minionsSettingSources
    }

    // MARK: - argv

    /// Extra flags for a companion spawn, in the order they read best on `ps`.
    func spawnArguments() -> [String] {
        Self.arguments(dropMCP: dropGlobalMCPServers, sources: settingSources, tools: tools)
    }

    /// Extra flags for a minion spawn. No `--tools`: a worker needs the lot.
    func minionArguments() -> [String] {
        Self.arguments(dropMCP: minionsDropGlobalMCPServers,
                       sources: minionsSettingSources, tools: [])
    }

    /// Pure, so the argv can be reasoned about (and diffed) without touching disk.
    static func arguments(dropMCP: Bool, sources: [String], tools: [String]) -> [String] {
        var args: [String] = []
        if dropMCP {
            // an empty server map plus --strict-mcp-config: the CLI loads these
            // servers and *only* these servers, which is none of them
            args += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        }
        let kept = sources.filter { knownSettingSources.contains($0) }
        // all three (or none named) is the CLI's own default — say nothing
        if !kept.isEmpty, Set(kept) != Set(knownSettingSources) {
            args += ["--setting-sources", kept.joined(separator: ",")]
        }
        let keptTools = tools.filter { !$0.isEmpty }
        if !keptTools.isEmpty {
            args += ["--tools", keptTools.joined(separator: ",")]
        }
        return args
    }

    static let knownSettingSources = ["user", "project", "local"]

    // MARK: - disk

    /// Read once per launch. The file is bob's, seeded with the defaults above
    /// the first time anything asks; after that the owner's copy wins and bob
    /// never rewrites it. A file that doesn't parse is left exactly as it is —
    /// bob falls back to the defaults and says why in `state/bridge-stderr.log`,
    /// because silently overwriting a hand-edited config is worse than ignoring it.
    nonisolated static let current: CompanionLoadout = load()

    nonisolated static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("companion-loadout.json")
    }

    nonisolated private static func load() -> CompanionLoadout {
        let url = fileURL
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else {
            let fresh = CompanionLoadout()
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fresh.seedFile().write(to: url, atomically: true, encoding: .utf8)
            return fresh
        }
        guard let decoded = try? JSONDecoder().decode(CompanionLoadout.self, from: data) else {
            let sink = ClaudeBridge.stderrSink(
                root: fm.homeDirectoryForCurrentUser.appendingPathComponent("bob", isDirectory: true))
            try? sink.write(contentsOf: Data(
                "[bob:loadout] state/companion-loadout.json didn't parse — using bob's defaults, file left alone\n".utf8))
            return CompanionLoadout()
        }
        return decoded
    }

    /// The seeded file, written by hand rather than by JSONEncoder so the `_note`
    /// reads like prose and the keys stay in a sensible order.
    func seedFile() -> String {
        func list(_ xs: [String]) -> String {
            xs.map { "\"\($0)\"" }.joined(separator: ", ")
        }
        return """
        {
          "_note": [
            "how much of a coding terminal bob's companion carries. read once at launch;",
            "delete a key to take bob's default back, delete the file to have it reseeded.",
            "",
            "the companion used to inherit the whole machine — ~94 user skills, 5 plugins,",
            "9 MCP servers, 30 built-in tools — 53,573 tokens of prompt before you typed a",
            "word (27% of a 200k window). with this file it is about 32,000.",
            "",
            "dropGlobalMCPServers: worth 2,277 tokens. nothing in bob calls an MCP tool.",
            "settingSources: which claude settings files the companion reads. dropping",
            "  \\"user\\" drops ~/.claude/settings.json and with it the global skills, the",
            "  plugins, and the terminal-shaped hooks — 9,356 tokens. ~/bob/.claude still",
            "  loads, so bob's own skills stay. put \\"user\\" back to run /ship, /qa and the",
            "  rest of the terminal suite in bob's own chat.",
            "tools: the built-ins the companion may see; each costs its schema every turn.",
            "  Bash 4,118 · Task 3,634 · AskUserQuestion 1,389 · Read 1,260 · WebFetch 699 ·",
            "  WebSearch 659 · Edit 579 · Write 360 · TaskOutput 543 · TaskStop 302.",
            "  [] means every built-in tool.",
            "",
            "work sessions (the tabs) are never slimmed — they have to be the same claude",
            "you get in a terminal. minions lose only their MCP servers.",
            "",
            "measured 2026-08-19 on claude 2.1.235, --model sonnet, cwd ~/bob."
          ],
          "dropGlobalMCPServers": \(dropGlobalMCPServers),
          "settingSources": [\(list(settingSources))],
          "tools": [
            \(list(tools))
          ],
          "minionsDropGlobalMCPServers": \(minionsDropGlobalMCPServers),
          "minionsSettingSources": [\(list(minionsSettingSources))]
        }

        """
    }
}
