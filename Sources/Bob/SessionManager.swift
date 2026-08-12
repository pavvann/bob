import Foundation

// MARK: - status (D9)

/// What a session's dot says. One definition, two consumers: the tab strip
/// today, AttentionCenter's digests in phase 3 — so bob and the UI can never
/// disagree about which project needs the owner.
enum SessionStatus: String, Equatable, Sendable {
    case working            // a turn is in flight (or a process is coming up for one)
    case awaitingInput      // it stopped and wants something from the owner
    case needsAttention     // it stopped badly — errored turn, or the process dropped
    case done               // idle, last turn clean, nothing to say
    case error              // the session itself is down
}

/// PermissionPolicy lives in ClaudeSession.swift and has no business knowing
/// about disk, so the wire mapping rides here. A string, not an ordinal: adding
/// a case later can't renumber a file already on disk.
extension PermissionPolicy: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "askFirst" ? .askFirst : .auto     // unknown → the safe default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .askFirst ? "askFirst" : "auto")
    }
}

// MARK: - the registry

/// Owns every live ClaudeSession: bob-the-companion at index 0, work sessions
/// (one per project) after him. Work sessions survive a relaunch as *cold*
/// tabs — config on disk, no process until they're used.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    /// Feature flag for the persistent-session path. Registered default-true by
    /// ClaudeBridge; `defaults write app.bob.mac bob.streamingSession -bool false`
    /// puts the whole thing (companion, tabs, restore) back to sleep.
    static let streamingFlagKey = "bob.streamingSession"
    static var streamingEnabled: Bool {
        UserDefaults.standard.bool(forKey: streamingFlagKey)
    }

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published var activeID: UUID? = nil

    /// bob himself — session #0. ClaudeBridge mirrors `sessions.first`, so index
    /// 0 is *reserved*: the companion inserts at the front, work sessions append
    /// behind him, whatever order they arrive in.
    var companion: ClaudeSession? { sessions.first }
    var active: ClaudeSession? { sessions.first(where: { $0.id == activeID }) ?? companion }
    /// Everything but bob — the tabs, and exactly what the state file holds.
    var workSessions: [ClaudeSession] { sessions.filter { $0.id != companionID } }

    /// Which session is the companion. Identity, not position, so a launch race
    /// (restore before spawn) can't make a work session masquerade as bob.
    private(set) var companionID: UUID?
    private var restoredFromDisk = false
    private let stateFile: URL

    /// The state file is injected so a harness can exercise persistence against
    /// a temp path and never write into the owner's `~/bob/state/sessions.json`.
    init(stateFile: URL? = nil) {
        self.stateFile = stateFile ?? BobHome.shared.root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    // MARK: - launch

    /// Spawn-at-launch entry point — BobApp calls this right after
    /// BobHome.bootstrapIfNeeded to hide the ~8s cold start, and brings last
    /// launch's tabs back with it. Idempotent: called again by ClaudeBridge
    /// once ~/bob is real, in case the flag wasn't registered yet the first time.
    func launchCompanionIfEnabled() {
        guard Self.streamingEnabled else { return }
        if companionID == nil {
            spawn(SessionConfig(
                cwd: BobHome.shared.root,
                appendSystemPrompt: nil,    // lenses ride in later via setAppendSystemPrompt
                permissions: .auto,         // behavior parity with today's bridge (edge 11)
                model: Self.preferredCompanionModel(),
                name: "bob",
                voiced: true
            ))
        }
        restoreWorkSessions()
        // the manager's ear opens with the registry — status transitions in
        // any work session become digests in bob's own thread (D9)
        AttentionCenter.shared.start()
    }

    /// Last launch's work sessions come back as cold tabs: config only, no
    /// process — and the same conversation, resumed (see SessionRecord). Each
    /// live claude is a 150–300MB node process (risk #6), so nothing spawns
    /// until `activate`/`send` asks. Sessions whose project has been moved or
    /// deleted are dropped from the file with a note in the stderr log.
    /// Idempotent.
    func restoreWorkSessions() {
        guard Self.streamingEnabled, !restoredFromDisk else { return }
        restoredFromDisk = true
        if companionID == nil { launchCompanionIfEnabled() }   // bob claims index 0 first
        guard let data = try? Data(contentsOf: stateFile) else { return }

        let split = Self.prune(Self.decodeRecords(data), exists: Self.isDirectory)
        for record in split.kept where !hasWorkSession(cwd: record.cwd) {
            sessions.append(makeSession(record.config))
        }
        for record in split.gone {
            note("dropped restored session '\(record.name)' — \(record.cwd) is gone")
        }
        if !split.gone.isEmpty { save() }   // the file forgets what disk forgot
    }

    // MARK: - spawn / activate / close

    /// Bring a session up. Work sessions spawn on demand — only the companion
    /// is always-on.
    @discardableResult
    func spawn(_ config: SessionConfig) -> ClaudeSession {
        let session = makeSession(config)
        if config.voiced, companionID == nil {
            // `voiced` is the companion's mark (work sessions are never voiced),
            // and bob always takes the front seat — ClaudeBridge reads
            // sessions.first as him.
            sessions.insert(session, at: 0)
            companionID = session.id
        } else {
            sessions.append(session)
            save()
        }
        if activeID == nil { activeID = session.id }
        session.spawn()
        return session
    }

    /// A raw claude in a project directory: no lens, no voice, just that
    /// project's own CLAUDE.md. Idempotent per cwd — the "+" picker can't fork a
    /// second process onto one project, and a cold restored tab wakes up instead.
    @discardableResult
    func spawnWorkSession(cwd: URL, name: String? = nil, model: String? = nil,
                          permissions: PermissionPolicy = .auto) -> ClaudeSession {
        let dir = cwd.standardizedFileURL
        if let existing = workSessions.first(where: { $0.config.cwd.standardizedFileURL == dir }) {
            if case .unspawned = existing.state { existing.spawn() }
            return existing
        }
        return spawn(SessionConfig(
            cwd: dir,
            appendSystemPrompt: nil,        // raw claude — no persona layer (plan D-config)
            permissions: permissions,
            model: model,
            name: name ?? Self.defaultName(for: dir),
            voiced: false                   // only bob speaks
        ))
    }

    // MARK: - model choice

    /// The aliases the CLI resolves itself — bob never hardcodes a dated id.
    static let modelChoices = ["opus", "sonnet", "haiku", "fable"]

    /// `~/bob/state/model` — one word, the companion's model. Absent = opus:
    /// bob's chat is conversation, not heavy lifting, and the CLI's own
    /// default (the newest, priciest tier) has burned a real spend cap once.
    static func preferredCompanionModel() -> String? {
        let file = BobHome.shared.stateDir.appendingPathComponent("model")
        let word = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if word == "default" { return nil }     // explicit opt back into CLI default
        return word.isEmpty ? "opus" : word
    }

    /// Switch a session's model in place — conversation intact (drain doorway).
    /// The companion's choice persists in state/model; a work session's rides
    /// its SessionRecord like every other config field.
    func setModel(_ alias: String?, for id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.setModel(alias)
        if id == companionID {
            let file = BobHome.shared.stateDir.appendingPathComponent("model")
            try? (alias ?? "default").write(to: file, atomically: true, encoding: .utf8)
        } else {
            save()
        }
    }

    /// Make a session the one CenterStage renders — and light it up if it's
    /// still cold. A `.failed` tab stays failed; retrying is `session.spawn()`,
    /// an explicit second click, not a side effect of looking at it.
    func activate(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        activeID = id
        if case .unspawned = session.state { session.spawn() }
    }

    /// Route a prompt at a session, spawning first if the tab is cold. Calling
    /// `session.send` on an unspawned session would client-queue the text with
    /// no process to ever flush it — that queue drains on a process's first init.
    func send(_ text: String, to id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if case .unspawned = session.state { session.spawn() }
        session.send(text)
    }

    // MARK: - bob's hand (D9 — the owner commands, via prefix)

    /// `>name text` lands here: the text goes to that session as a user-role
    /// message wearing its provenance — `[via bob] …` — a visible `you` row in
    /// the session's transcript, marked by the prefix itself. Queue semantics
    /// on a busy session (probe 1.7): it runs as the next turn, terminal-style,
    /// never interrupting. Spawn-if-cold same as send(_:to:).
    func inject(_ text: String, into id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if case .unspawned = session.state { session.spawn() }
        session.send("[via bob] \(text)", source: .injected)
    }

    /// The explicit stop verb — `>name! text` — and the ONLY path that ever
    /// interrupts a work session; nothing calls it implicitly (D9). Interrupt,
    /// wait for the aborted result to land the session back on idle (probe
    /// 1.4), then inject. The message is held client-side through the stop
    /// because the CLI's own queue is ambiguous after an interrupt
    /// (still_queued) — and it is never delivered to a session that died
    /// instead of stopping.
    func stopAndTell(_ text: String, to id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if case .unspawned = session.state { session.spawn() }
        guard session.isStreaming else {
            session.send("[via bob] \(text)", source: .injected)
            return
        }
        session.interrupt()
        Task { @MainActor [weak session] in
            for _ in 0..<600 {                       // bounded: 30s, watchdog scale
                guard let session else { return }
                switch session.state {
                case .idle:
                    session.send("[via bob] \(text)", source: .injected)
                    return
                case .failed, .unspawned:
                    return                           // it died — don't pile on
                default:
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }

    /// The owner closing a tab: graceful stdin close, out of the registry, out
    /// of the state file. Quitting is the opposite — `shutdown()` leaves the
    /// file alone so every tab comes back.
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].close()
        sessions.remove(at: index)
        if companionID == id { companionID = nil }
        if activeID == id { activeID = sessions.first?.id }
        save()
    }

    /// App-quit teardown (D1): close every stdin — companion and work sessions
    /// alike — give the processes 2s to exit on their own, terminate stragglers.
    /// Deliberately does NOT touch the state file: the tabs are meant to be
    /// there tomorrow.
    func shutdown() async {
        guard !sessions.isEmpty else { return }
        for session in sessions { session.close() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for session in sessions where session.isRunning { session.terminateNow() }
        sessions.removeAll()
        activeID = nil
        companionID = nil
        restoredFromDisk = false
    }

    // MARK: - status derivation (D9)

    /// A function of what the session (and the permission broker) already
    /// publish — no clocks, no side effects, same answer every call. Branch
    /// order *is* the precedence: what is true now beats what was true last
    /// turn.
    static func status(of session: ClaudeSession) -> SessionStatus {
        // 1. the session itself is down: spawn threw, handshake timed out, or it
        //    died twice in a minute.
        if case .failed = session.state { return .error }
        // 2. the process dropped under us. Every permanent notice ClaudeSession
        //    appends is session health ("dropped — reconnecting"); live
        //    background-task rows all carry a taskId. Last row = nothing has
        //    happened since, so the owner still hasn't heard.
        if let last = session.entries.last, last.role == .notice, last.taskId == nil {
            return .needsAttention
        }
        // 3. an ask-first tool call is holding for the owner. Checked before
        //    the in-flight branch on purpose: the turn is technically active,
        //    but nothing moves until someone answers — that's awaiting, not
        //    working (P3a).
        if UIPermissionBroker.shared.count(for: session.id) > 0 { return .awaitingInput }
        // 4. something is in flight — a turn, or a process coming up for one.
        switch session.state {
        case .turnActive, .interrupting, .spawning, .draining: return .working
        default: break
        }
        // 5. the last turn ended badly. An interrupt reports is_error too
        //    (terminal_reason aborted_streaming) and is NOT attention — the
        //    owner asked for it (edge 4).
        if let result = session.lastResult, result.isError,
           result.terminalReason != "aborted_streaming" {
            return .needsAttention
        }
        // 6. it wants the owner: tools were denied, or the reply ends in a question.
        if let result = session.lastResult, !result.deniedTools.isEmpty { return .awaitingInput }
        if endsInQuestion(session.entries.last(where: { $0.role == .bob && !$0.hidden })?.text) {
            return .awaitingInput
        }
        // 7. idle — or never spawned — with a clean last turn.
        return .done
    }

    func status(of session: ClaudeSession) -> SessionStatus { Self.status(of: session) }

    /// "should i force-push?" → awaiting. Trailing emphasis or brackets don't
    /// hide the mark: `**…?**` and `(…?)` still count.
    static func endsInQuestion(_ text: String?) -> Bool {
        guard var trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return false }
        while let last = trimmed.last, "*_`)\"']".contains(last) { trimmed.removeLast() }
        return trimmed.last == "?"
    }

    // MARK: - the state file (~/bob/state/sessions.json)

    /// One work session as it survives a relaunch. The companion is absent by
    /// design — it's bridge-managed and spawned fresh every launch.
    ///
    /// `id` is the CLI conversation this tab last ran, and restore hands it
    /// straight back — with `resumed: true`, so the first spawn says `--resume`
    /// rather than `--session-id` (the CLI hard-errors on an id it already owns:
    /// "Session ID … is already in use", rc=1, probed on 2.1.228). That is what
    /// makes a restored tab the *same* conversation, history and all, and keeps
    /// its transcript under ~/.claude/projects named the same forever.
    struct SessionRecord: Codable, Equatable {
        var id: UUID
        var cwd: String                     // absolute path, plain string so the file reads
        var name: String
        var model: String?                  // absent = CLI default
        var permissions: PermissionPolicy?  // absent = .auto

        var config: SessionConfig {
            SessionConfig(
                sessionId: id,
                cwd: URL(fileURLWithPath: cwd),
                appendSystemPrompt: nil,
                permissions: permissions ?? .auto,
                model: model,
                name: name,
                voiced: false,
                resumed: true
            )
        }
    }

    /// Pure, so a harness can prove the roundtrip without touching ~/bob.
    static func encodeRecords(_ records: [SessionRecord]) -> Data? {
        let encoder = JSONEncoder()
        // the owner (and bob, reading state/) sees real paths, not \/escaped ones
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(records)
    }

    /// A half-written or hand-mangled file loses the whole list rather than
    /// taking the app down with it — the tabs are a convenience, not the state.
    static func decodeRecords(_ data: Data) -> [SessionRecord] {
        (try? JSONDecoder().decode([SessionRecord].self, from: data)) ?? []
    }

    /// Split restored records by whether the project is still on disk. `exists`
    /// is injected so this stays a pure function.
    static func prune(_ records: [SessionRecord],
                      exists: (String) -> Bool) -> (kept: [SessionRecord], gone: [SessionRecord]) {
        var kept: [SessionRecord] = []
        var gone: [SessionRecord] = []
        for record in records {
            if exists(record.cwd) { kept.append(record) } else { gone.append(record) }
        }
        return (kept, gone)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// "~/Code/lootgo" → "lootgo". A path that ends up nameless still gets
    /// something typeable rather than an empty tab.
    static func defaultName(for cwd: URL) -> String {
        let last = cwd.standardizedFileURL.lastPathComponent
        return last.isEmpty || last == "/" ? "session" : last
    }

    private func save() {
        guard let data = Self.encodeRecords(workSessions.map(record(for:))) else { return }
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    private func record(for session: ClaudeSession) -> SessionRecord {
        SessionRecord(
            id: session.config.sessionId,
            cwd: session.config.cwd.path,
            name: session.config.name,
            model: session.config.model,
            permissions: session.config.permissions
        )
    }

    // MARK: - plumbing

    private func makeSession(_ config: SessionConfig) -> ClaudeSession {
        ClaudeSession(
            config: config,
            claudePath: ClaudeBridge.claudePath,
            stderrSink: ClaudeBridge.stderrSink(root: BobHome.shared.root)
        )
    }

    private func hasWorkSession(cwd: String) -> Bool {
        let dir = URL(fileURLWithPath: cwd).standardizedFileURL
        return workSessions.contains { $0.config.cwd.standardizedFileURL == dir }
    }

    /// Registry forensics land in the same log a curious owner already checks:
    /// state/bridge-stderr.log.
    private func note(_ line: String) {
        let sink = ClaudeBridge.stderrSink(root: BobHome.shared.root)
        try? sink.write(contentsOf: Data("[bob:sessions] \(line)\n".utf8))
    }
}
