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

/// Owns every live session: bob-the-companion at index 0, work sessions (one
/// per project, claude or codex) after him. Work sessions survive a relaunch as
/// *cold* tabs — config on disk, nothing running until they're used.
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
    /// Codex tabs. A separate list rather than a widened `sessions`, because
    /// `sessions` is what the bridge mirrors and what AttentionCenter watches —
    /// both of which mean *claude* — while the band, the stage and the state
    /// file read `workTabs`, which is both kinds in the order they arrived.
    @Published private(set) var codexSessions: [CodexSession] = []
    /// Tab order across providers, by session id. The registry can't derive it:
    /// two lists have no shared index, and a claude tab opened after a codex one
    /// must not jump in front of it.
    @Published private(set) var tabOrder: [UUID] = []
    @Published var activeID: UUID? = nil

    /// bob himself — session #0. ClaudeBridge mirrors `sessions.first`, so index
    /// 0 is *reserved*: the companion inserts at the front, work sessions append
    /// behind him, whatever order they arrive in.
    var companion: ClaudeSession? { sessions.first }
    var active: ClaudeSession? { sessions.first(where: { $0.id == activeID }) ?? companion }
    /// Every claude but bob.
    var workSessions: [ClaudeSession] { sessions.filter { $0.id != companionID } }

    /// Every tab, either provider, in the order they were opened — the band,
    /// ⌘1…⌘9, `>name` dispatch and the state file all read this one list.
    /// Anything missing from `tabOrder` (a spawn path that forgot to register)
    /// lands at the end rather than disappearing off the band.
    var workTabs: [SessionRef] {
        var refs: [SessionRef] = []
        for id in tabOrder {
            if let session = sessions.first(where: { $0.id == id && $0.id != companionID }) {
                refs.append(.claude(session))
            } else if let session = codexSessions.first(where: { $0.id == id }) {
                refs.append(.codex(session))
            }
        }
        let known = Set(refs.map(\.id))
        refs += workSessions.filter { !known.contains($0.id) }.map(SessionRef.claude)
        refs += codexSessions.filter { !known.contains($0.id) }.map(SessionRef.codex)
        return refs
    }

    /// Whichever session is on stage, bob's own thread included.
    var activeRef: SessionRef? {
        guard let id = activeID else { return nil }
        if let session = sessions.first(where: { $0.id == id }) { return .claude(session) }
        if let session = codexSessions.first(where: { $0.id == id }) { return .codex(session) }
        return nil
    }

    /// The active tab when it isn't bob — what the work stage renders.
    var activeWorkTab: SessionRef? {
        guard let ref = activeRef, ref.id != companionID else { return nil }
        return ref
    }

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
        for record in split.kept where !hasWorkTab(cwd: record.cwd, provider: record.provider) {
            switch record.provider {
            case .claude:
                let session = makeSession(record.config)
                sessions.append(session)
                tabOrder.append(session.id)
                hydrate(session)
            case .codex:
                // cold, exactly like a claude tab: the thread is named in the
                // record and `open()` resumes it on the first send or click.
                let session = makeCodexSession(record.codexConfig)
                codexSessions.append(session)
                tabOrder.append(session.id)
            }
        }
        for record in split.gone {
            note("dropped restored session '\(record.name)' — \(record.cwd) is gone")
        }
        if !split.gone.isEmpty { save() }   // the file forgets what disk forgot
    }

    /// Put a restored tab's conversation back on screen.
    ///
    /// The record carries the conversation, so the CLI comes back holding the
    /// whole thread — but the transcript is a fresh empty store, and until now
    /// nothing ever read the thread back. The tab said the project's name over an
    /// empty stage and `/resume` couldn't help, because it hides the conversation
    /// you're already in. So the only way to see your own history was to pick a
    /// *different*, older thread — which repointed the tab and took the newest
    /// turns off both the screen and the model.
    ///
    /// One bounded read per restored tab, off the main actor, at restore. Not a
    /// watcher and not a poll: `reload` declines the moment the session has
    /// anything of its own to say, so a tab that wakes up and starts talking
    /// while this read is in flight keeps what it said.
    private func hydrate(_ session: ClaudeSession) {
        let conversation = session.config.sessionId
        let cwd = session.config.cwd
        Task { [weak session] in
            let turns = await Task.detached(priority: .utility) { () -> [ResumeIndex.Turn] in
                guard let url = ResumeIndex.transcript(of: conversation, cwd: cwd) else { return [] }
                return ResumeIndex.history(of: url)
            }.value
            guard let session, session.config.sessionId == conversation else { return }
            session.reload(history: turns.map {
                TranscriptEntry(role: $0.fromYou ? .you : .bob, text: $0.text)
            })
        }
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
            tabOrder.append(session.id)
            save()
        }
        if activeID == nil { activeID = session.id }
        session.spawn()
        return session
    }

    /// A codex session in a project directory — the same gesture as
    /// `spawnWorkSession`, one process further away: every codex tab shares one
    /// `codex app-server`, so this opens a thread rather than a process.
    /// Idempotent per cwd within the provider (a claude tab and a codex tab in
    /// one project are two different things, and both are allowed).
    @discardableResult
    func openCodexSession(cwd: URL, name: String? = nil, model: String? = nil,
                          effort: String? = nil,
                          approvalPolicy: CodexApprovalPolicy = .onRequest,
                          sandbox: CodexSandboxPolicy? = nil,
                          resumeThreadId: String? = nil) -> CodexSession {
        let dir = cwd.standardizedFileURL
        if let existing = codexSessions.first(where: { $0.config.cwd.standardizedFileURL == dir }) {
            if case .unspawned = existing.state { existing.open() }
            return existing
        }
        let session = makeCodexSession(CodexSessionConfig(
            cwd: dir,
            name: name ?? Self.defaultName(for: dir),
            approvalPolicy: approvalPolicy,
            sandbox: sandbox,
            model: model,
            effort: effort,
            resumeThreadId: resumeThreadId
        ))
        codexSessions.append(session)
        tabOrder.append(session.id)
        if activeID == nil { activeID = session.id }
        save()
        session.open()
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

    /// Back to bob: his thread on stage, any surface put away. Every way home
    /// — the chip, ⌘0, the esc layer — routes through here, so they can't
    /// drift apart. A no-op in compatibility mode, where there's no companion
    /// session to return to.
    func goHome() {
        SurfaceRouter.shared.close()
        if let id = companionID { activate(id) }
    }

    /// ⌘1…⌘9 — the nth work session. Out of range does nothing rather than
    /// clamping to the last tab: a shortcut that lands somewhere you didn't
    /// ask for is worse than one that quietly declines.
    func jumpToWorkSession(_ index: Int) {
        let tabs = workTabs
        guard index >= 0, index < tabs.count else { return }
        SurfaceRouter.shared.close()
        activate(tabs[index].id)
    }

    /// Make a session the one CenterStage renders — and light it up if it's
    /// still cold. A `.failed` tab stays failed; retrying is `session.spawn()`,
    /// an explicit second click, not a side effect of looking at it.
    func activate(_ id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            activeID = id
            if case .unspawned = session.state { session.spawn() }
        } else if let session = codexSessions.first(where: { $0.id == id }) {
            activeID = id
            if case .unspawned = session.state { session.open() }
        }
    }

    /// Route a prompt at a session, spawning first if the tab is cold. Calling
    /// `session.send` on an unspawned session would client-queue the text with
    /// no process to ever flush it — that queue drains on a process's first init.
    func send(_ text: String, to id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            if case .unspawned = session.state { session.spawn() }
            session.send(text)
        } else if let session = codexSessions.first(where: { $0.id == id }) {
            // a codex send before the thread exists is safe: it queues and
            // drains the moment `open()` reaches `.idle`
            if case .unspawned = session.state { session.open() }
            session.send(text)
        }
    }

    // MARK: - bob's hand (D9 — the owner commands, via prefix)

    /// `>name text` lands here: the text goes to that session as a user-role
    /// message wearing its provenance — `[via bob] …` — a visible `you` row in
    /// the session's transcript, marked by the prefix itself. Queue semantics
    /// on a busy session (probe 1.7): it runs as the next turn, terminal-style,
    /// never interrupting. Spawn-if-cold same as send(_:to:).
    func inject(_ text: String, into id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            if case .unspawned = session.state { session.spawn() }
            session.send("[via bob] \(text)", source: .injected)
        } else if let session = codexSessions.first(where: { $0.id == id }) {
            // mid-turn this becomes a `turn/steer` rather than a queued turn —
            // still delivered without interrupting, which is what D9 promises
            if case .unspawned = session.state { session.open() }
            session.send("[via bob] \(text)", source: .injected)
        }
    }

    /// The explicit stop verb — `>name! text` — and the ONLY path that ever
    /// interrupts a work session; nothing calls it implicitly (D9). Interrupt,
    /// wait for the aborted result to land the session back on idle (probe
    /// 1.4), then inject. The message is held client-side through the stop
    /// because the CLI's own queue is ambiguous after an interrupt
    /// (still_queued) — and it is never delivered to a session that died
    /// instead of stopping.
    func stopAndTell(_ text: String, to id: UUID) {
        if let codex = codexSessions.first(where: { $0.id == id }) {
            stopAndTellCodex(text, to: codex)
            return
        }
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

    /// Same shape for a codex tab, one lever shorter: there is no per-session
    /// process to stop, so the stop is `turn/interrupt` and the wait is for the
    /// turn to land back on idle.
    private func stopAndTellCodex(_ text: String, to session: CodexSession) {
        if case .unspawned = session.state { session.open() }
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
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].close()
            sessions.remove(at: index)
            if companionID == id { companionID = nil }
        } else if let index = codexSessions.firstIndex(where: { $0.id == id }) {
            let session = codexSessions.remove(at: index)
            // the thread survives on disk — that's what makes it resumable —
            // but nothing of it may be left running or waiting on an answer
            Task { await session.close() }
        } else {
            return
        }
        tabOrder.removeAll { $0 == id }
        if activeID == id { activeID = sessions.first?.id ?? codexSessions.first?.id }
        save()
    }

    /// App-quit teardown (D1): close every stdin — companion and work sessions
    /// alike — give the processes 2s to exit on their own, terminate stragglers.
    /// Deliberately does NOT touch the state file: the tabs are meant to be
    /// there tomorrow.
    func shutdown() async {
        await shutdownCodex()
        guard !sessions.isEmpty else { return }
        for session in sessions { session.close() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for session in sessions where session.isRunning { session.terminateNow() }
        sessions.removeAll()
        tabOrder.removeAll()
        activeID = nil
        companionID = nil
        restoredFromDisk = false
    }

    /// The codex half of the goodbye, and the one place `CodexServer.shutdown()`
    /// is called from. Each session stands its own turn down first (concurrently
    /// — a quit may not cost one interrupt's leash per tab) and refuses whatever
    /// it was holding for an answer; only then does stdin close, so app-server
    /// has nothing pending and exits in milliseconds rather than taking the ~9s
    /// a clean close with work in flight is entitled to.
    ///
    /// Called unconditionally: the model dial can start app-server without any
    /// session existing, and an orphaned one would outlive bob.
    private func shutdownCodex() async {
        let codex = codexSessions
        codexSessions.removeAll()
        if !codex.isEmpty {
            await withTaskGroup(of: Void.self) { group in
                for session in codex { group.addTask { await session.close() } }
            }
        }
        await CodexServer.shared.shutdown()
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
        if let last = session.transcript.entries.last, last.role == .notice, last.taskId == nil {
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
        if endsInQuestion(session.transcript.entries.last(where: { $0.role == .bob && !$0.hidden })?.text) {
            return .awaitingInput
        }
        // 7. idle — or never spawned — with a clean last turn.
        return .done
    }

    func status(of session: ClaudeSession) -> SessionStatus { Self.status(of: session) }

    /// The codex reading of the same five words. Two differences from claude's,
    /// both because the protocol says it plainly instead of leaving it to be
    /// inferred: `activeFlags` names a park (`waitingOnApproval`) whether or not
    /// bob could draw a card for it, and the last turn's own reported status
    /// stands in for parsing a closing message. The trailing-notice branch is
    /// deliberately absent — a resumed thread's history lands under a notice,
    /// and claude's equivalent would read that as a session that just dropped.
    static func status(of session: CodexSession) -> SessionStatus {
        if case .failed = session.state { return .error }
        if UIPermissionBroker.shared.count(for: session.id) > 0 { return .awaitingInput }
        if !session.activeFlags.isEmpty { return .awaitingInput }
        switch session.state {
        case .turnActive, .interrupting, .spawning: return .working
        default: break
        }
        if session.lastTurn?.status == .failed { return .needsAttention }
        if endsInQuestion(session.transcript.entries.last(where: { $0.role == .bob && !$0.hidden })?.text) {
            return .awaitingInput
        }
        return .done
    }

    static func status(of ref: SessionRef) -> SessionStatus {
        switch ref {
        case .claude(let session): return status(of: session)
        case .codex(let session): return status(of: session)
        }
    }

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
    /// its transcript under ~/.claude/projects named the same forever. On a
    /// codex tab `id` names nothing on codex's side — `codex.threadId` is what
    /// resumes the conversation — so there it's just a stable bob-side handle.
    struct SessionRecord: Codable, Equatable {
        var id: UUID
        var cwd: String                     // absolute path, plain string so the file reads
        var name: String
        var model: String?                  // absent = CLI default (claude) / codex config
        var permissions: PermissionPolicy?  // absent = .auto — claude only
        /// Absent = claude, so a file written before codex existed still reads,
        /// and a file of nothing but claude tabs still reads the way it did.
        var kind: SessionProvider?
        /// The codex-only half. Nested rather than five more optional columns:
        /// the two providers configure nothing in common except cwd, name and
        /// model.
        var codex: CodexRecord?

        struct CodexRecord: Codable, Equatable {
            /// What `thread/resume` needs next launch — the whole reason a
            /// restored codex tab is the same conversation.
            var threadId: String?
            var effort: String?
            /// Only `readOnly` is ever written: absent means the GUI default,
            /// writes scoped to the session's own cwd, which is computed from
            /// cwd rather than stored so a moved project can't leave a stale
            /// writable root behind.
            var sandbox: String?
            var approval: String?
        }

        var provider: SessionProvider { kind ?? .claude }

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

        var codexConfig: CodexSessionConfig {
            CodexSessionConfig(
                sessionId: id,
                cwd: URL(fileURLWithPath: cwd),
                name: name,
                approvalPolicy: CodexApprovalPolicy(rawValue: codex?.approval ?? "") ?? .onRequest,
                sandbox: codex?.sandbox == "readOnly" ? .readOnly : nil,
                model: model,
                effort: codex?.effort,
                resumeThreadId: codex?.threadId
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

    /// "~/Code/webapp" → "webapp". A path that ends up nameless still gets
    /// something typeable rather than an empty tab.
    static func defaultName(for cwd: URL) -> String {
        let last = cwd.standardizedFileURL.lastPathComponent
        return last.isEmpty || last == "/" ? "session" : last
    }

    /// Write the registry now. A session that repoints itself no longer has to
    /// remember to ask — `onConversationChanged`, wired in `makeSession`, does it
    /// for every path including the ones nobody thought of. This stays as the
    /// door for anything that edits a config field the manager doesn't own.
    func persist() { save() }

    private func save() {
        // in workTabs order, so the band comes back the way it was left
        guard let data = Self.encodeRecords(workTabs.map(record(for:))) else { return }
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    private func record(for ref: SessionRef) -> SessionRecord {
        switch ref {
        case .claude(let session): return record(for: session)
        case .codex(let session): return record(for: session)
        }
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

    private func record(for session: CodexSession) -> SessionRecord {
        SessionRecord(
            id: session.config.sessionId,
            cwd: session.config.cwd.path,
            name: session.config.name,
            model: session.config.model,
            permissions: nil,
            kind: .codex,
            codex: SessionRecord.CodexRecord(
                threadId: session.threadId ?? session.config.resumeThreadId,
                effort: session.config.effort,
                sandbox: session.config.sandbox == .readOnly ? "readOnly" : nil,
                approval: session.config.approvalPolicy.rawValue
            )
        )
    }

    // MARK: - plumbing

    private func makeSession(_ config: SessionConfig) -> ClaudeSession {
        let session = ClaudeSession(
            config: config,
            claudePath: ClaudeBridge.claudePath,
            stderrSink: ClaudeBridge.stderrSink(root: BobHome.shared.root)
        )
        // whenever a session stops being the conversation the file says it is —
        // `/resume`, or a CLI that answered init with a different id — the
        // registry writes, or the next launch restores the thread just left
        session.onConversationChanged = { [weak self] in self?.save() }
        return session
    }

    private func makeCodexSession(_ config: CodexSessionConfig) -> CodexSession {
        let session = CodexSession(config: config, server: .shared)
        // the dial and the thread id both live in the state file, so every way
        // either can change writes it — including the ones nobody thought of
        session.onConfigChanged = { [weak self] in self?.save() }
        return session
    }

    private func hasWorkTab(cwd: String, provider: SessionProvider) -> Bool {
        let dir = URL(fileURLWithPath: cwd).standardizedFileURL
        switch provider {
        case .claude:
            return workSessions.contains { $0.config.cwd.standardizedFileURL == dir }
        case .codex:
            return codexSessions.contains { $0.config.cwd.standardizedFileURL == dir }
        }
    }

    /// Registry forensics land in the same log a curious owner already checks:
    /// state/bridge-stderr.log.
    private func note(_ line: String) {
        let sink = ClaudeBridge.stderrSink(root: BobHome.shared.root)
        try? sink.write(contentsOf: Data("[bob:sessions] \(line)\n".utf8))
    }
}
