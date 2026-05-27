import Foundation

@MainActor
final class BobHome: ObservableObject {
    static let shared = BobHome()

    enum Status: Equatable {
        case checking
        case bootstrapping(String)
        case ready
        case failed(String)
    }

    @Published var status: Status = .checking
    @Published var welcomeNote: String? = nil
    @Published var projectCount: Int = 0

    let root: URL
    private let home: URL

    private init() {
        self.home = FileManager.default.homeDirectoryForCurrentUser
        self.root = home.appendingPathComponent("bob", isDirectory: true)
    }

    // MARK: paths

    var soulPath: URL { root.appendingPathComponent("SOUL.md") }
    var userPath: URL { root.appendingPathComponent("USER.md") }
    var memoryPath: URL { root.appendingPathComponent("MEMORY.md") }
    var indexPath: URL { root.appendingPathComponent("index.md") }
    var logPath: URL { root.appendingPathComponent("log.md") }
    var claudeMdPath: URL { root.appendingPathComponent("CLAUDE.md") }

    var wikiDir: URL { root.appendingPathComponent("wiki", isDirectory: true) }
    var skillsDir: URL { root.appendingPathComponent("skills", isDirectory: true) }
    var rawDir: URL { root.appendingPathComponent("raw", isDirectory: true) }
    var stateDir: URL { root.appendingPathComponent("state", isDirectory: true) }
    var wikiBobDir: URL { wikiDir.appendingPathComponent("bob", isDirectory: true) }
    var wikiTemplatesDir: URL { wikiDir.appendingPathComponent("templates", isDirectory: true) }

    var isInitialized: Bool {
        FileManager.default.fileExists(atPath: soulPath.path)
    }

    // MARK: bootstrap

    func bootstrapIfNeeded() async {
        if isInitialized {
            // Even if previously bootstrapped, top up any seed files / dirs
            // we've added since (idempotent — never overwrites the user's edits).
            try? createDirectoryStructure()
            try? ensureSeedFiles()
            status = .ready
            return
        }
        await bootstrap()
    }

    /// Rescan projects and rewrite `wiki/projects.md`. Safe to call any time.
    func refreshProjects() async {
        status = .bootstrapping("scanning your projects...")
        let scanner = ProjectScanner(home: home)
        let projects = await scanner.scan()
        do {
            try writeProjectsPage(projects: projects)
            try appendLog(op: "ingest", title: "projects map (refresh, \(projects.count) entries)")
            status = .ready
        } catch {
            status = .failed("project refresh failed: \(error.localizedDescription)")
        }
    }

    private func bootstrap() async {
        do {
            status = .bootstrapping("creating ~/bob/...")
            try createDirectoryStructure()

            status = .bootstrapping("writing seed files...")
            try ensureSeedFiles()

            status = .bootstrapping("scanning your projects...")
            let scanner = ProjectScanner(home: home)
            let projects = await scanner.scan()

            status = .bootstrapping("writing wiki/projects.md...")
            try writeProjectsPage(projects: projects)
            try writeInitialIndex(projectCount: projects.count)
            try appendLog(op: "ingest", title: "bootstrap | mapped \(projects.count) projects")

            projectCount = projects.count
            welcomeNote = "set up ~/bob/. mapped \(projects.count) projects.\nopen ~/bob/ to see what i know."
            status = .ready
        } catch {
            status = .failed("bootstrap failed: \(error.localizedDescription)")
        }
    }

    private func createDirectoryStructure() throws {
        let fm = FileManager.default
        let minionsActive = root.appendingPathComponent("minions/active", isDirectory: true)
        let minionsDone = root.appendingPathComponent("minions/done", isDirectory: true)
        for dir in [root, wikiDir, skillsDir, rawDir, stateDir, wikiBobDir, wikiTemplatesDir, minionsActive, minionsDone] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Writes each seed file only if it doesn't exist. Safe to call repeatedly.
    private func ensureSeedFiles() throws {
        let fm = FileManager.default

        let seeds: [(URL, String)] = [
            (soulPath, seedSoul),
            (userPath, seedUser),
            (claudeMdPath, seedClaudeMd),
            (wikiBobDir.appendingPathComponent("vision.md"), seedVision),
            (wikiBobDir.appendingPathComponent("ux.md"), seedUx),
            (wikiTemplatesDir.appendingPathComponent("article.md"), seedArticleTemplate),
            (wikiTemplatesDir.appendingPathComponent("raw.md"), seedRawTemplate),
            (skillsDir.appendingPathComponent("play-music.md"), seedPlayMusicSkill),
        ]

        for (path, content) in seeds {
            if !fm.fileExists(atPath: path.path) {
                try content.write(to: path, atomically: true, encoding: .utf8)
            }
        }

        if !fm.fileExists(atPath: logPath.path) {
            let header = """
            # log

            append-only chronological ledger. one entry per session or operation. greppable:
            `grep \"^## \\[\" log.md | tail -5`

            """
            try header.write(to: logPath, atomically: true, encoding: .utf8)
        }
    }

    private func writeProjectsPage(projects: [ProjectScanner.Project]) throws {
        let body = renderProjectsMarkdown(projects)
        let path = wikiDir.appendingPathComponent("projects.md")
        try body.write(to: path, atomically: true, encoding: .utf8)
    }

    private func writeInitialIndex(projectCount: Int) throws {
        let body = """
        # index

        bob's wiki catalog. claude reads this first when answering a query — each table below maps one topic. when ingesting a new source, add a row to the right table (or create a new section if the topic is new). summaries are one line; dates iso-8601.

        ## bob

        self-knowledge: what bob is, how it should behave, design constraints.

        | article | summary | updated |
        |---------|---------|---------|
        | [vision](wiki/bob/vision.md) | what bob is and isn't; the conviction behind it. | 2026-05-25 |
        | [ux principles](wiki/bob/ux.md) | chrome-free, files-for-audit-not-use, tile grid, voice as peer modality. | 2026-05-25 |

        ## projects

        map of the user's projects across `~/Code/` and `~/.claude/projects/`.

        | article | summary | updated |
        |---------|---------|---------|
        | [projects map](wiki/projects.md) | \(projectCount) projects grouped active / code-only / orphaned. regenerated by bob's wrapper, not via ingest. | 2026-05-24 |

        ## people

        (no entries yet.)

        ## templates

        reference templates for new wiki pages. not loaded by query; copied from when authoring.

        - `wiki/templates/article.md` — frontmatter + article body skeleton.
        - `wiki/templates/raw.md` — raw source page skeleton.

        """
        try body.write(to: indexPath, atomically: true, encoding: .utf8)
    }

    /// Appends a karpathy-style log entry: `## [YYYY-MM-DD] <op> | <title>`.
    private func appendLog(op: String, title: String) throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let entry = "## [\(fmt.string(from: Date()))] \(op) | \(title)\n"
        guard let data = entry.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logPath.path),
           let handle = try? FileHandle(forWritingTo: logPath) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try entry.write(to: logPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: projects.md rendering

    private func renderProjectsMarkdown(_ projects: [ProjectScanner.Project]) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let active = projects.filter { $0.category == .active }
        let codeOnly = projects.filter { $0.category == .codeOnly }
        let orphaned = projects.filter { $0.category == .orphaned }

        var out = """
        ---
        type: source
        updated: \(stamp.prefix(10))
        sources:
          - scan of ~/Code/
          - scan of ~/.claude/projects/
        ---

        # projects — the map

        bob scanned `~/Code/` and `~/.claude/projects/` on \(stamp).

        **summary:** \(projects.count) total — \(active.count) active (code + claude history), \(codeOnly.count) code-only, \(orphaned.count) orphaned (claude history but code is gone).

        this file is regenerated when bob rescans, not via ingest. hand-edits will be clobbered by the next rescan. for durable notes on a specific project, create a dedicated wiki page and link it from here.

        ---

        """

        out += section("Active — has code and Claude history", projects: active)
        out += section("Code only — exists on disk, no Claude history yet", projects: codeOnly)
        out += section("Orphaned — Claude history exists but the code directory is gone", projects: orphaned)

        return out
    }

    private func section(_ title: String, projects: [ProjectScanner.Project]) -> String {
        guard !projects.isEmpty else { return "" }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        var out = "## \(title)\n\n"
        for p in projects {
            var line = "- **\(p.name)**"
            if let path = p.realPath {
                let pretty = path.path.replacingOccurrences(of: home.path, with: "~")
                line += " — `\(pretty)`"
            }
            var meta: [String] = []
            if p.sessionCount > 0 {
                meta.append("\(p.sessionCount) session\(p.sessionCount == 1 ? "" : "s")")
            }
            if let last = p.lastActivity {
                meta.append("last activity \(dateFmt.string(from: last))")
            }
            if !meta.isEmpty {
                line += " · " + meta.joined(separator: " · ")
            }
            out += line + "\n"
            if let snip = p.snippet, !snip.isEmpty {
                out += "  > \(snip)\n"
            }
        }
        return out + "\n"
    }

    // MARK: seed content

    private var seedSoul: String { """
    # SOUL.md — who bob is

    bob is a place to think out loud with my computer.

    **voice:** quiet, observant, plain. doesn't perform. doesn't pad. doesn't ask "would you like me to..." — just says the thing.

    **default mode:** listen first. ask one clarifying question only if a real ambiguity blocks the response. otherwise answer.

    **memory ethic:** what bob knows about me lives in plain markdown files in `~/bob/` that i can read, edit, and `git diff`. bob never hides knowledge.

    **not:** a productivity tool. not a second brain. not an assistant in the corporate-helper sense.
    """
    }

    private var seedUser: String { """
    # USER.md — what bob knows about you

    bob fills this in over time as you talk. start by replacing the `??` placeholders below with real values, or just let bob ask about them as topics come up:

    - name: ??
    - email: ??
    - machine: ?? (terminal, editor, package manager preferences)
    - work: ??
    - building: ?? (what you're currently working on)
    - git identity: ?? (any rules about how git should be configured)

    claude updates this file inline when you tell it something durable about yourself. you can also edit it directly.
    """
    }

    private var seedClaudeMd: String { """
    # CLAUDE.md — bob's operating manual

    you are claude, invoked by bob (a swiftui mac app) inside `~/bob/`. **this directory is your long-term memory layer for the user.** read it. update it as you learn. there is no separate "ingest" or "lint" phase — every conversation is also a chance to refine these files inline.

    ## what's here

    **root-level (read at the start of every conversation):**

    - `SOUL.md` — your identity and voice. how you talk. rarely changes; only edit when the user explicitly redirects your behaviour.
    - `USER.md` — facts about the user. update when he tells you something durable.
    - `MEMORY.md` — holding pen for recent observations. iso-dated bullets, append within a session.
    - `index.md` — catalog of `wiki/` pages with one-line summaries.

    **topical (read on-demand):**

    - `wiki/<topic>/<article>.md` — topic pages for things that deserve their own space.
    - `wiki/templates/` — skeletons for new pages.

    **storage and history:**

    - `log.md` — append-only chronological ledger. format: `## [YYYY-MM-DD] <op> | <title>`.
    - `raw/` — immutable source material. read but **never** modify.
    - `skills/<name>.md` — procedural recipes you read whenever the user's request matches a skill's trigger phrases (e.g. "play killer queen" matches `skills/play-music.md`).
    - `state/` — small JSON snapshots bob's swift code keeps fresh (e.g. `music.json`). read for "what's playing?" / "what's next?" instead of shelling out.

    ## how you update files (continuously, mid-conversation)

    when something durable surfaces during a chat, edit inline — before or after responding.

    - the user tells you a fact about himself → edit `USER.md`.
    - half-formed observation worth remembering → append a dated bullet to `MEMORY.md`.
    - the user redirects your behaviour → edit `SOUL.md`, one focused line.
    - a `MEMORY.md` topic outgrows a few bullets → promote into `wiki/<topic>/<article>.md`, add a row to `index.md`, mark the originals `→ moved to ...`.

    rules: never silent-overwrite; never invent; prefer adding to rewriting; iso-8601 dates.

    ## how you answer

    1. read `SOUL.md`, `USER.md`, `MEMORY.md`, `index.md` at the top of the session.
    2. if the question maps to a topic in `index.md`, read those `wiki/` page(s).
    3. answer in soul-aligned voice. cite with `[Title](wiki/topic/file.md)` when actually relevant.
    4. if anything durable surfaced, update the relevant file before finishing the turn.

    if it's small-talk and nothing durable surfaces, just answer.

    ## voice (match SOUL.md)

    lowercase by default. terse. no padding. no "happy to help." no "let me know if..." closers.

    ## conventions

    - wiki pages: per `wiki/templates/article.md`. word cap 1200; split when bigger.
    - raw pages: per `wiki/templates/raw.md`. immutable.
    - index.md: one section per topic, table with `article | summary | updated`.
    - topic dirs: one level only. kebab-case filenames. iso-8601 dates.

    ## what you can do

    bob runs you with full shell access on this mac. you can:

    - read / write / edit files anywhere (preferentially in `~/bob/`, but elsewhere when asked).
    - open mac apps (`open -a "Spotify"`), urls (`open https://...`), files (`open path/to/file`).
    - run applescript (`osascript -e '...'`), text-to-speech (`say "..."`).
    - query system state (`pmset -g batt`, `defaults read`, etc).

    prefer the lightest-weight option. don't shell out when a markdown edit would suffice.

    ## hard rules

    - never modify `raw/`.
    - never silent-overwrite.
    - never invent.
    - don't run destructive commands without confirming: `rm -rf`, force-push, anything irreversible.
    - don't ask permission for trivial things — the user trusts you. that's the whole point.

    ## what this borrows from

    karpathy's LLM wiki gist (https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) for the directory shape. **deviation:** no discrete ingest or lint — files are updated continuously, paperclip-style.
    """
    }

    private var seedVision: String { """
    ---
    type: concept
    updated: YYYY-MM-DD
    sources:
      - SOUL.md
      - ARCHITECTURE.md (in bob's source repo)
    ---

    # bob — vision

    ## overview

    bob is a personal mac app — one window, blurred background, no chrome. text input, voice input, voice output. underneath it wraps the claude cli. on the surface it's a place you can think out loud with your computer, with a long-term memory layer you own and can read.

    ## what bob is striving to be

    - the **interface**, not a folder. when bob "knows" something, you should reach it by *talking*, not by opening files.
    - **conversational** first. all interaction goes through chat. voice is a peer modality, not an add-on.
    - **owned**. all of bob's memory is plain markdown in `~/bob/`. no opaque vector store, no hidden state.
    - **inspectable**. anything bob knows can be opened in a text editor, edited by hand, diffed in git. files-as-audit-trail, not files-as-primary-surface.

    ## what bob is explicitly not

    - not a productivity tool. doesn't suggest todos, doesn't track tasks, doesn't propose agendas.
    - not a second brain. doesn't auto-index "for later."
    - not an agent. doesn't take actions on the world in v1 — only talks.
    - not a chatgpt clone with chrome. no sidebar of past chats. no "new chat" button. past is in `log.md`.

    ## the conviction

    bob is built on the conviction that current AI tools feel like traditional apps with AI bolted on — they're enabled by AI but still shaped by the apps they replaced. bob aims to be something else — fewer affordances, more conversation.

    karpathy's framing of the LLM Wiki (april 2026 gist) is the closest existing pattern: an explicit, navigable knowledge artifact you own, that an LLM helps you build and query. bob extends that with a conversational surface and a tile-grid dashboard.

    ## see also

    - [ux principles](ux.md)
    - [SOUL.md](../../SOUL.md)
    - [USER.md](../../USER.md)
    """
    }

    private var seedUx: String { """
    ---
    type: concept
    updated: YYYY-MM-DD
    sources:
      - bob design conversations
    ---

    # bob — ux principles

    operating constraints on bob's interface.

    ## chrome-free

    no titlebar buttons beyond close. no sidebar. no history pane. no "new chat" button. no settings dropdown. the window IS the conversation.

    session history lives in `log.md` and `raw/`, not in the UI.

    ## files are for audit, not primary use

    bob's wiki at `~/bob/` exists so you can inspect what bob knows, edit it, and `git diff` changes. it is NOT the primary way you access that knowledge. talking to bob is.

    corollary: bob should never instruct you to "open finder" or "go check the folder." that defeats the point.

    ## tiles, not chat-bubbles

    bob's main view is a 2×2 tile grid (work / music / memory / talk). chat is one tile of equal weight. no traditional chat-bubble UI, no left-rail thread list.

    other tiles ambient-track context from other parts of your life. the memory tile reads live from `MEMORY.md`.

    ## visual

    - ghostty-style blurred window via `NSVisualEffectView` (`.hudWindow` material, `.behindWindow` blending)
    - ultraThinMaterial cards for tiles, corner radius 22
    - rounded input bar inside the talk tile (corner radius 30) with a slow comet-style blue accent traveling its perimeter
    - lowercase typography by default
    - sf rounded font

    ## voice

    bidirectional. you speak (push-to-talk via mic button) or type. bob can speak responses (toggle, off by default) or just stream text.

    reading is faster than listening — text out is the default. voice out is opt-in.

    ## no overlays, no surveillance

    no always-on screen capture. no always-on mic. no notifications. no overlay that watches your screen. bob is summoned, not ambient.

    ## window behavior

    - floating mac panel, never enters fullscreen mode (`collectionBehavior = .fullScreenNone`)
    - resizable but not maximizable
    - min 720×480, ideal 960×640, max 1280×920
    - follows you across spaces (`.moveToActiveSpace`)

    ## see also

    - [vision](vision.md)
    - [SOUL.md](../../SOUL.md)
    """
    }

    private var seedArticleTemplate: String { """
    ---
    type: source | entity | concept | synthesis
    updated: YYYY-MM-DD
    sources:
      - raw/<topic>/<file>.md
    ---

    # {title}

    > sources: {author1, YYYY-MM-DD}{; author2, YYYY-MM-DD}

    ## overview

    {one paragraph.}

    ## {body sections}

    {prose. cap total page word count at 1200. when bigger, split into a subdirectory.}

    ## see also

    - [related article](other-article.md)              # same topic
    - [related article](../other-topic/other.md)       # cross-topic
    """
    }

    private var seedRawTemplate: String { """
    # {title}

    > source: {url or origin}
    > collected: {YYYY-MM-DD}
    > published: {YYYY-MM-DD or unknown}

    {original content. formatting cleaned. opinions preserved. immutable after writing.}
    """
    }

    private var seedPlayMusicSkill: String { """
    # skill: play-music

    triggers (case-insensitive, match anywhere in the user's request):

    - "play <song>", "play <song> by <artist>", "queue <song>", "put on <song>"
    - "pause music", "stop music", "next track", "previous track"
    - "start music" (no song — resume queue)

    bob can play **library tracks** (via AppleScript) and **catalog tracks** (via MusicKit through `bob://music/play`).

    ## play a specific song

    1. canonicalise via iTunes Search:
       ```
       curl -s "https://itunes.apple.com/search?term=<urlencoded>&entity=song&limit=1"
       ```
       parse `results[0].trackId`, `trackName`, `artistName`. empty → tell user, stop.

    2. try library first:
       ```
       osascript -e 'tell application "Music"
         try
           play (first track of library playlist 1 whose name is "<trackName>" and artist contains "<artistName>")
           return "played"
         on error
           return "not in library"
         end try
       end tell'
       ```
       output `played` → confirm and stop.

    3. catalog fallback — hand off to bob:
       ```
       open -g "bob://music/play?id=<trackId>"
       ```
       bob plays via MusicKit's `SystemMusicPlayer`. first time will prompt for Apple Music access.

    4. confirm: "playing <trackName> by <artistName>."

    ## transport controls

    - "play" / "resume" → `osascript -e 'tell application "Music" to play'`
    - "pause" → `osascript -e 'tell application "Music" to pause'`
    - "next" / "skip" → `osascript -e 'tell application "Music" to next track'`
    - "previous" → `osascript -e 'tell application "Music" to previous track'`

    ## permissions

    TCC Automation for Music on first AppleScript call. Apple Music access on first catalog playback.

    ## notes

    music tile updates via `com.apple.Music.playerInfo` distributed notification. catalog debug info at `~/bob/state/music-debug.log`.
    """
    }
}
