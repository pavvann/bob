import Foundation

// MARK: - configuration

/// Everything that makes a session what it is. Bob-the-companion is just
/// config — cwd ~/bob, a lens/persona riding the system prompt, voice on. A
/// work session is cwd ~/Code/whatever, raw claude, voice off. ClaudeSession
/// itself knows nothing about "bob"; persona is the caller's business.
struct SessionConfig {
    var sessionId: UUID = UUID()
    var cwd: URL
    var appendSystemPrompt: String? = nil   // nil = raw claude (project CLAUDE.md only)
    var permissions: PermissionPolicy = .auto
    var model: String? = nil                // nil = CLI default
    var name: String                        // tab label / log prefix
    var voiced: Bool = false                // onSentence wiring
    /// `sessionId` names a conversation the CLI already has on disk, so the
    /// very first spawn must `--resume` it instead of `--session-id` (which
    /// hard-errors: "Session ID … is already in use"). Restored tabs set this;
    /// a brand-new session leaves it false.
    var resumed: Bool = false
}

enum PermissionPolicy: Equatable {
    /// --permission-mode auto — the CLI's classifier judges each tool call.
    case auto
    /// manual + stdio prompt tool: every tool call becomes a can_use_tool
    /// control_request routed through the PermissionBroker (probe 1.6).
    /// Approval UI lands phase 3; the wiring exists now.
    case askFirst
}

// MARK: - permission seam (phase 3)

enum PermissionDecision {
    case allow
    /// Allow *and* adopt the permission updates the CLI itself offered with the
    /// ask (`permission_suggestions`, probe 1.6) — the "always allow" button.
    case allowAdopting([PermissionSuggestion])
    case deny(message: String)
}

/// Ask-first sessions forward can_use_tool requests here; the CLI blocks the
/// turn until a decision comes back. The protocol isolates the blast radius
/// if the hidden stdio flag ever breaks (risk #1).
@MainActor
protocol PermissionBroker {
    func decide(_ request: PermissionRequest) async -> PermissionDecision
    /// The process behind these asks is gone — drop them. Nobody is waiting on
    /// the answer any more, and a card offering to approve a dead session's
    /// Write is worse than no card.
    func abandon(sessionId: UUID)
}

extension PermissionBroker {
    func abandon(sessionId: UUID) {}
}

/// The no-op broker `.auto` sessions carry. --permission-mode auto never asks,
/// so this never fires; it exists so the seam is real (and so harnesses can
/// answer without a UI).
struct AutoAllowBroker: PermissionBroker {
    func decide(_ request: PermissionRequest) async -> PermissionDecision { .allow }
}

// MARK: - the session

/// One persistent `claude -p --input-format stream-json` process and the
/// state machine wrapped around it (plan D1/D2/D4/D5). Owns the process,
/// stdin writer, stdout reader, transcript entries, speech flushing,
/// interrupt, crash-respawn with --resume, and lens swaps via graceful
/// respawn. Published surface is @MainActor for SwiftUI; framing/decoding
/// happens off-main in one reader task that feeds events back in order.
@MainActor
final class ClaudeSession: ObservableObject, Identifiable {
    enum TurnSource: Equatable { case user, injected, spontaneous }

    enum State: Equatable {
        case unspawned
        case spawning                 // watchdog 20s
        case idle
        case turnActive(TurnSource)
        case interrupting
        case draining                 // deliberate exit in flight; respawn on exit
        case failed(String)
    }

    enum Role: Equatable { case you, bob, notice }

    let id = UUID()
    private(set) var config: SessionConfig

    /// Message content lives in its own @Observable store (P2b): a streamed
    /// token wakes the one row reading it, and the @Published surface below
    /// speaks only at boundaries.
    let transcript = TranscriptStore()

    @Published private(set) var state: State = .unspawned
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastResult: TurnResult? = nil
    /// What claude is blocked on, waiting for a person to choose. The turn stays
    /// `turnActive` while it's up — nothing moves until it's answered.
    @Published private(set) var question: SessionQuestion? = nil
    /// Agents this session has set running, newest last. Finished rows linger so
    /// you can read the outcome rather than watching them vanish.
    @Published private(set) var agents: [SessionAgent] = []
    /// How full this conversation's context was at the end of the last turn, as a
    /// percentage of the model's window. Session state, not transcript — so it
    /// lives on the @Published surface and moves once a turn, at the boundary,
    /// never on a delta. nil until a turn has actually reported usage.
    @Published private(set) var contextUsedPct: Double? = nil
    /// The tier word for whatever model this session is running — "opus". The
    /// dial's alias to begin with, replaced by whatever the CLI's init line
    /// actually names. nil when neither has said (the bare CLI default).
    @Published private(set) var modelShortName: String? = nil

    /// Called with each completed sentence as the reply streams (D5). Only
    /// fires when `config.voiced`. Wired to VoiceOutput by the view layer.
    var onSentence: ((String) -> Void)?
    /// This session now names a different conversation than the registry has on
    /// disk — either because `/resume` repointed it or because the CLI answered
    /// init with an id bob didn't ask for. Whoever owns the state file wires this
    /// to its write; without it the next launch restores the conversation you
    /// just left.
    var onConversationChanged: (() -> Void)?
    /// Who answers can_use_tool. Ask-first sessions get the UI broker at init
    /// (the approval card is the whole point of the mode); `.auto` sessions keep
    /// the no-op one, which nothing ever calls.
    var broker: PermissionBroker = AutoAllowBroker()

    /// The single derived Bool CenterStage/BobPulse key off (D2).
    var isStreaming: Bool {
        switch state {
        case .turnActive, .interrupting: return true
        default: return false
        }
    }

    /// Most recent completed-or-streaming reply (adapter convenience).
    var lastResponse: String { transcript.entries.last(where: { $0.role == .bob })?.text ?? "" }

    var pid: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning ?? false }

    /// Same env scrub ClaudeBridge does, so the child doesn't see itself as
    /// nested inside another claude session and refuse to start.
    static let scrubbedEnv = [
        "CLAUDECODE",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_PROJECT_DIR",
    ]

    private let claudePath: String
    private let stderrSink: FileHandle
    /// How long a settled task's notice lingers before it's swept. Injected so
    /// harnesses don't have to wait out the real thing.
    private let taskNoticeLinger: TimeInterval
    private var process: Process?
    private var stdinPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var eventTaps: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]
    private var noteTaps: [UUID: AsyncStream<SessionNote>.Continuation] = [:]

    /// Sends made while no live process could take them (spawning/draining) —
    /// flushed the moment init lands (D4). Nothing is ever silently dropped.
    private var clientQueue: [String] = []
    /// Sends already written to a busy process's stdin; the CLI queues them
    /// natively and runs each as the next turn (probe 1.7).
    private var cliQueuedSends = 0
    /// The in-flight bob entry — deltas append here. Not "the last bob
    /// entry": queued user turns may already sit after it. A reference, not
    /// an index, so a task notice sweeping itself above can't skew it.
    private var currentBob: TranscriptEntry?
    /// Text not yet handed to `onSentence` — its own buffer, never an index
    /// into a string that mutates under it (a reused String.Index is UB).
    private var unspoken = ""
    /// A lens change requested mid-turn (D4.2) — `.some(newPrompt)` applies at
    /// the next idle; the prompt itself may be nil (@none).
    private var pendingPromptChange: String?? = nil
    private var pendingModelDrain = false
    /// False until the CLI confirms the session exists (first init). First
    /// spawn uses --session-id; every respawn uses --resume (D1). Seeded true
    /// for a restored conversation — its id is already on disk, so its very
    /// first spawn is a resume too (`SessionConfig.resumed`).
    private var sessionOnDisk = false
    /// True only once the CLI has *said* so (a system/init). `sessionOnDisk` can
    /// be seeded true by a restored tab whose id never actually reached the CLI —
    /// that id resumes into "No conversation found", and the difference between
    /// believed and confirmed is what makes the one --session-id retry safe.
    private var confirmedOnDisk = false
    private var resumeFallbackUsed = false
    /// Set when a spawn carrying `--permission-prompt-tool` died before saying a
    /// word: this claude doesn't know the hidden flag (risk #1). Ask-first then
    /// degrades to manual mode — every tool auto-denied, each denial surfaced.
    private var stdioPromptUnsupported = false
    /// request_id of the readiness handshake sent at spawn (see launchProcess).
    private var handshakeId: String?
    private var recentDeaths: [Date] = []
    private var closing = false
    /// Pending sweeps, one per task id — cancelled and re-armed whenever the
    /// task speaks again, so a late ping never leaves two rows or a stale timer.
    private var taskSweeps: [String: Task<Void, Never>] = [:]
    /// The newest assistant message's token counts, held un-published until the
    /// turn ends: a turn writes several assistant messages and only the last
    /// one's window is the one you're looking at. Tagged with the conversation it
    /// was measured in, so a reading can't outlive the thread it describes.
    private var latestUsage: (conversation: UUID, tokens: TokenUsage)?
    /// The denominator `contextUsedPct` divides by — the reported model's window,
    /// or the dial alias's before the CLI has spoken.
    private var contextWindow = ContextWindow.fallback

    /// `claudePath`/`stderrSink` are injected (SessionManager passes
    /// ClaudeBridge's statics) so the core stays testable standalone.
    init(config: SessionConfig, claudePath: String, stderrSink: FileHandle,
         taskNoticeLinger: TimeInterval = 10) {
        self.config = config
        self.claudePath = claudePath
        self.stderrSink = stderrSink
        self.taskNoticeLinger = taskNoticeLinger
        self.sessionOnDisk = config.resumed
        self.modelShortName = ContextWindow.shortName(for: config.model)
        self.contextWindow = ContextWindow.size(for: config.model)
        if config.permissions == .askFirst { self.broker = UIPermissionBroker.shared }
    }

    // MARK: - public verbs

    /// Boot the process. The manager calls this once at spawn time; all
    /// respawns are internal and strictly exit-then-spawn.
    func spawn() {
        switch state {
        case .failed:
            recentDeaths.removeAll()    // explicit retry resets the crash-loop guard
            launchProcess()
        case .unspawned:
            launchProcess()
        default:
            break
        }
    }

    func send(_ rawPrompt: String, hidden: Bool = false, source: TurnSource = .user) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if case .failed(let reason) = state {
            lastError = "session is down (\(reason))"
            return
        }
        lastError = nil
        transcript.append(TranscriptEntry(role: .you, text: prompt, hidden: hidden))
        switch state {
        case .idle:
            writeUserMessage(prompt)
            beginTurn(source: source)
        case .turnActive, .interrupting:
            // terminal-style injection: the CLI queues stdin messages and
            // runs each as the next turn (probe 1.7)
            writeUserMessage(prompt)
            cliQueuedSends += 1
        case .unspawned, .spawning, .draining:
            clientQueue.append(prompt)
        case .failed:
            break   // unreachable — handled above
        }
    }

    /// Stop the current turn without killing the process (probe 1.4). The CLI
    /// answers with an aborted result; the entry gets "(interrupted)".
    func interrupt() {
        guard case .turnActive = state else { return }
        writeLine([
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ])
        state = .interrupting
        note(.activityChanged)   // listeners record it: this stop is the owner's, not news
    }

    /// Swap the lens/persona riding this session (D4). Takes resolved prompt
    /// text, not a lens spec — resolution is per process epoch, done by the
    /// caller. Idle: graceful respawn now (drain → exit → --resume with the
    /// new prompt), masked by typing time. Mid-turn: applied at next result.
    func setAppendSystemPrompt(_ prompt: String?) {
        switch state {
        case .unspawned, .failed:
            config.appendSystemPrompt = prompt
        case .idle:
            config.appendSystemPrompt = prompt
            beginDrain()
        case .turnActive, .interrupting, .spawning, .draining:
            pendingPromptChange = .some(prompt)
        }
    }

    /// Same drain doorway as a lens swap: the conversation survives (--resume),
    /// only the model under it changes. Config updates at once — a restored tab
    /// keeps the choice even if the respawn waits for the turn to end.
    func setModel(_ model: String?) {
        config.model = model
        // the caption follows the choice at once, not at the respawn: showing the
        // model you just left would be worse than showing none. Back to the CLI
        // default means bob has no word for it until the next init line says one.
        adoptModel(model)
        switch state {
        case .unspawned, .failed:
            break                        // next spawn reads config
        case .idle:
            beginDrain()
        case .turnActive, .interrupting, .spawning, .draining:
            pendingModelDrain = true
        }
    }

    /// Hard reset (D1): new conversation id, cleared transcript, lens off.
    /// The old process is torn down immediately and a fresh one spawns with
    /// --session-id.
    func reset() {
        config.sessionId = UUID()
        config.appendSystemPrompt = nil
        sessionOnDisk = false
        transcript.replaceAll([])
        lastError = nil
        lastResult = nil
        forgetContextUse()
        clientQueue.removeAll()
        cliQueuedSends = 0
        currentBob = nil
        unspoken = ""
        pendingPromptChange = nil
        recentDeaths.removeAll()
        cancelSweeps()
        switch state {
        case .unspawned:
            break
        case .failed:
            state = .unspawned
            launchProcess()
        default:
            state = .draining          // respawn (fresh id) happens on exit
            process?.terminate()       // hard reset doesn't wait for the turn
        }
    }

    /// Pick up a conversation this project already has on disk (`/resume`):
    /// same tab, different thread. The process goes down and comes back with
    /// `--resume <id>`, and the transcript on screen is replaced by that
    /// conversation's own history so what you read matches what the model
    /// remembers. The lens stays — resuming changes which conversation you're
    /// in, not who bob is.
    ///
    /// The seam is announced (a notice row), because a switch nobody can see is
    /// a switch that gets narrated wrong later.
    func resume(conversationId: UUID, history: [TranscriptEntry]) {
        guard conversationId != config.sessionId else { return }
        config.sessionId = conversationId
        onConversationChanged?()
        sessionOnDisk = true            // it exists: --resume, not --session-id
        confirmedOnDisk = false         // this process hasn't confirmed it yet
        resumeFallbackUsed = false      // a new id earns its own single retry
        transcript.replaceAll(history)
        transcript.append(TranscriptEntry(role: .notice, text: history.isEmpty
            ? "resumed this conversation — nothing readable on disk, but the model has it"
            : "resumed this conversation — the last \(history.count) turns, read from disk"))
        lastError = nil
        lastResult = nil
        forgetContextUse()
        clientQueue.removeAll()
        cliQueuedSends = 0
        currentBob = nil
        unspoken = ""
        pendingPromptChange = nil
        pendingModelDrain = false
        recentDeaths.removeAll()
        cancelSweeps()
        switch state {
        case .unspawned:
            break                       // the next spawn reads the new id
        case .failed:
            state = .unspawned
            launchProcess()
        default:
            // you asked to be somewhere else — don't wait out the turn
            state = .draining
            process?.terminate()
        }
    }

    /// Put this conversation's own history back on screen without moving the
    /// session: same id, same process, same turn if one is in flight. The
    /// conversation a tab is already on is the one case `resume` can't serve —
    /// it guards against repointing a session at itself, correctly — and it is
    /// also the case that matters most, because a restored tab comes back holding
    /// the right conversation and an empty transcript.
    ///
    /// Never while a reply is streaming, whoever asked: `replaceAll` would drop
    /// the in-flight row out of `entries` while the pump kept appending to the
    /// object, and the rest of that answer would go nowhere.
    ///
    /// An *automatic* reload (a tab waking up from the state file) also declines
    /// the moment the session has anything of its own on screen — a snapshot of
    /// disk is already older than whatever was just said. A reload the owner
    /// asked for by picking this thread in `/resume` overwrites, because they can
    /// see what's there and asked for the file's version anyway.
    ///
    /// Success says nothing. A trailing notice is how this session reports its
    /// own *health* — `SessionManager.status` reads one as `.needsAttention`
    /// before it looks at anything else, and AttentionCenter turns that into a
    /// digest — so announcing a routine load would have flagged every restored
    /// tab as a session that needs the owner. The thread arriving on screen is
    /// the only receipt a successful read needs. Failure still speaks, but only
    /// when someone asked and got nothing back.
    func reload(history: [TranscriptEntry], deliberate: Bool = false) {
        guard !isStreaming else { return }
        if !deliberate, transcript.entries.contains(where: { $0.role != .notice }) { return }
        guard !history.isEmpty else {
            if deliberate {
                appendNotice("nothing readable on disk for this conversation — the model still has it")
            }
            return
        }
        transcript.replaceAll(history)
    }

    /// Graceful goodbye: close stdin, the process exits on its own (probe
    /// 1.1). The manager terminates stragglers after a grace period (D1).
    func close() {
        closing = true
        watchdog?.cancel()
        if process == nil {
            state = .unspawned
        } else {
            closeStdin()
        }
    }

    /// Last resort at app quit — kill anything still alive after the grace.
    func terminateNow() {
        process?.terminate()
    }

    // MARK: - event fan-out (the phase-3 manager substrate, D9)

    /// Every decoded event, multicast: each access mints an independent
    /// stream. Bounded — a tap that stops draining loses its oldest events
    /// rather than growing a queue forever. Text deltas arrive already
    /// coalesced to the pump's ~16ms windows.
    var events: AsyncStream<StreamEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let key = UUID()
            eventTaps[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.eventTaps[key] = nil }
            }
        }
    }

    private func broadcast(_ event: StreamEvent) {
        for tap in eventTaps.values { tap.yield(event) }
    }

    /// The semantic beat: turn boundaries and health flips, nothing per-token.
    /// AttentionCenter listens here instead of objectWillChange, so a
    /// streaming turn wakes it a handful of times, not once per delta. Emitted
    /// after the mutation they describe — a consumer always reads post-change.
    enum SessionNote: Sendable {
        case turnBegan
        case activityChanged   // a notice landed / readiness moved — status may have changed
        case turnEnded
        case sessionFailed
    }

    var notes: AsyncStream<SessionNote> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let key = UUID()
            noteTaps[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.noteTaps[key] = nil }
            }
        }
    }

    private func note(_ n: SessionNote) {
        for tap in noteTaps.values { tap.yield(n) }
    }

    // MARK: - process lifecycle (D1)

    private func launchProcess() {
        precondition(process == nil, "two processes on one session id")
        state = .spawning

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = spawnArguments()
        proc.currentDirectoryURL = config.cwd

        var env = ProcessInfo.processInfo.environment
        for key in Self.scrubbedEnv { env.removeValue(forKey: key) }
        // launchd's bare PATH breaks plugin hooks that shell out to homebrew
        // tools (e.g. node) — give the child a real one (bl-0007).
        env["PATH"] = ClaudeBridge.spawnPATH
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderrSink

        // stdout → lines → events, in strict order: one detached task frames
        // and decodes off the main actor, then feeds the pump — which
        // coalesces text deltas to ~16ms windows and drops non-visual chatter
        // before anything crosses to the main actor. AsyncStream buffers
        // unboundedly, so the pipe never backs up against a busy UI.
        let bytes = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
        }
        let pump = StreamPump(session: self)
        let name = config.name
        let sink = stderrSink
        let reader = Task.detached(priority: .userInitiated) {
            var framer = LineFramer()
            var dropped = 0
            for await chunk in bytes {
                for line in framer.consume(chunk) {
                    let event = StreamJSON.decode(line)
                    if case .ignored(let forensic) = event {
                        if let forensic { Self.noteForensic(forensic, name: name, sink: sink) }
                        continue
                    }
                    await pump.ingest(event)
                }
                if framer.droppedLines > dropped {
                    dropped = framer.droppedLines
                    Self.noteForensic("(dropped oversized stdout line, >4MB)", name: name, sink: sink)
                }
            }
            // flush the pump's tail before the exit handler awaits us — a
            // final fragment must land before crash/drain handling runs
            await pump.finish()
        }
        readerTask = reader

        // exit runs strictly after the reader has delivered every trailing
        // event, so a final `result` line always lands before crash/drain
        // handling — no phantom "connection lost" on clean turn ends
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                _ = await reader.value
                self?.processExited(p)
            }
        }

        do {
            try proc.run()
        } catch {
            reader.cancel()
            stdout.fileHandleForReading.readabilityHandler = nil
            lastError = "couldn't start claude: \(error.localizedDescription)"
            state = .failed(lastError!)
            note(.sessionFailed)
            return
        }
        process = proc
        stdinPipe = stdin

        // the CLI stays silent until its first turn — there is no spontaneous
        // init at spawn (probed on 2.1.227; the plan's 7–8s figure was
        // measured with input already queued). the agent-SDK initialize
        // handshake gives a real readiness signal: the CLI answers it once
        // SessionStart hooks finish, and the session runs normally after.
        let handshake = UUID().uuidString
        handshakeId = handshake
        writeLine([
            "type": "control_request",
            "request_id": handshake,
            "request": ["subtype": "initialize"],
        ])

        // spawn watchdog (D2): handshake answers in ~5–8s cold, but the
        // user's SessionStart hooks were probed as slow as 23s under load —
        // 30s, not the plan's 20s, or healthy spawns get shot
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            self?.spawnTimedOut(proc)
        }
    }

    private func spawnArguments() -> [String] {
        // --verbose is REQUIRED with -p + stream-json output (plan 1.8)
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        switch config.permissions {
        case .auto:
            args += ["--permission-mode", "auto"]
            // The same hidden flag ask-first needs, for a different reason:
            // without a permission-prompt sink the CLI *disables* every tool
            // that requires a person, so AskUserQuestion doesn't exist and a
            // question can never reach the owner (probe 2026-08-13). Adding it
            // does NOT take ordinary permissions away from auto's classifier —
            // probed: a Bash call still went straight through, no can_use_tool.
            if !stdioPromptUnsupported { args += ["--permission-prompt-tool", "stdio"] }
        case .askFirst:
            args += ["--permission-mode", "manual"]
            // the hidden flag that turns manual mode from deny-by-default into a
            // real question (probe 1.6, verified on 2.1.227/228). A claude that
            // doesn't know it exits at once; we retry without it and say so.
            if !stdioPromptUnsupported { args += ["--permission-prompt-tool", "stdio"] }
        }
        // first spawn of a conversation creates (--session-id); every respawn
        // — crash, lens swap — resumes. same id, history intact (D1). no
        // --replay-user-messages: turns render locally, hidden ones stay hidden.
        args += [sessionOnDisk ? "--resume" : "--session-id", config.sessionId.uuidString.lowercased()]
        if let model = config.model { args += ["--model", model] }
        if let prompt = config.appendSystemPrompt { args += ["--append-system-prompt", prompt] }
        return args
    }

    private func spawnTimedOut(_ proc: Process) {
        guard proc === process, state == .spawning else { return }
        lastError = "claude didn't answer the readiness handshake within 30s"
        state = .failed(lastError!)
        note(.sessionFailed)
        proc.terminate()               // exit handler sees .failed and stays down
    }

    private func processExited(_ proc: Process) {
        guard proc === process else { return }   // stale epoch — ignore
        process = nil
        stdinPipe = nil
        readerTask = nil
        watchdog?.cancel()
        watchdog = nil
        // nothing is listening on the other end of an open ask any more
        broker.abandon(sessionId: id)

        if closing { state = .unspawned; return }

        switch state {
        case .unspawned, .failed:
            break
        case .draining:
            // planned exit (lens swap / reset) — the one legal respawn
            // doorway: strictly exit-then-spawn, never two processes on one
            // session id (edge 6)
            launchProcess()
        case .spawning:
            // a process that died before saying a word usually died of its
            // ARGUMENTS, not of bad luck — one targeted retry first
            if retryWithoutTheRefusedFlag() { return }
            respawnAfterUnexpectedDeath()
        case .idle:
            appendNotice("bob's session dropped — reconnecting")
            respawnAfterUnexpectedDeath()
        case .turnActive, .interrupting:
            // mid-turn death: close the in-flight entry and NEVER auto-resend
            // — tools may have half-run (edge 2). CLI-queued sends died with
            // the process; their prompts stay visible for a one-Enter re-send.
            if let entry = currentBob {
                transcript.set(activity: nil, of: entry)
                let tail = entry.text.isEmpty
                    ? "(connection lost — say that again?)"
                    : " (connection lost — say that again?)"
                transcript.append(text: tail, to: entry)
                if config.voiced { unspoken += tail }
                flushSpeakable(final: true)
                transcript.finalize(entry)
            }
            currentBob = nil
            unspoken = ""
            cliQueuedSends = 0
            appendNotice("bob's session dropped — reconnecting")
            respawnAfterUnexpectedDeath()
        }
    }

    /// Two ways a first spawn is dead on arrival, each worth exactly one retry:
    /// a persisted id the CLI never actually saw (`--resume` → "No conversation
    /// found", rc=1) and a claude too old for the hidden stdio prompt tool
    /// (risk #1). Neither is a crash, so neither counts toward the crash-loop
    /// guard — we asked for something this CLI couldn't give, and the fix is to
    /// stop asking for it.
    private func retryWithoutTheRefusedFlag() -> Bool {
        if sessionOnDisk, !confirmedOnDisk, !resumeFallbackUsed {
            resumeFallbackUsed = true
            sessionOnDisk = false          // --session-id: create it instead of resuming it
            launchProcess()
            return true
        }
        // Both modes now pass --permission-prompt-tool, so both need the retry: a
        // claude too old for it would otherwise take auto sessions down with it,
        // and auto sessions are the default.
        if !stdioPromptUnsupported {
            stdioPromptUnsupported = true
            appendNotice(config.permissions == .askFirst
                ? "this claude can't be asked first — running deny-by-default; each blocked tool gets a line"
                : "this claude can't relay questions — if it needs a choice it'll ask in the transcript")
            launchProcess()
            return true
        }
        return false
    }

    private func respawnAfterUnexpectedDeath() {
        let now = Date()
        recentDeaths = recentDeaths.filter { now.timeIntervalSince($0) < 60 }
        recentDeaths.append(now)
        guard recentDeaths.count < 2 else {
            // crash loop (D1): stop feeding the fire. P1c's bridge watches for
            // .failed and falls back to the legacy one-shot path.
            lastError = "crashed twice in a minute"
            state = .failed(lastError!)
            note(.sessionFailed)
            appendNotice("bob's session keeps dying — check state/bridge-stderr.log")
            return
        }
        launchProcess()                // --resume: history survives, same id
    }

    // MARK: - the state machine (D2)

    /// The pump's one doorway onto the main actor. Coalesced text lands
    /// first, then the boundary that flushed it — ordering survives the
    /// trip, and a window's worth of deltas costs one entries mutation.
    /// Text nil with no boundary is thinking chatter's idle check (D5).
    func applyPump(text: String?, boundary: StreamEvent?) {
        if let text {
            spontaneousIfIdle()
            broadcast(.streamEvent(.textDelta(text)))
            appendDelta(text)
        } else if boundary == nil {
            spontaneousIfIdle()
        }
        if let boundary { handle(boundary) }
    }

    private func handle(_ event: StreamEvent) {
        broadcast(event)
        switch event {
        case .initialized(let reported, let model):
            // init arrives at the start of EVERY turn (never spontaneously at
            // spawn) — it confirms the session file exists, and doubles as a
            // readiness fallback should a future CLI drop the handshake.
            //
            // Unless it came from a process we already walked away from. `/resume`
            // and `reset` change the conversation and terminate mid-turn, and the
            // dying process's last events still arrive after that — carrying the
            // OLD id, and an "it's on disk" that is true of a conversation this
            // session no longer is. Every one of those lands before the
            // replacement process exists (terminationHandler awaits the reader
            // before processExited clears `process`), so `.draining` is exactly
            // the corpse's window. Nothing in here has a legitimate effect during
            // it: becomeReadyIfSpawning already no-ops off `.spawning`.
            guard state != .draining else { break }
            sessionOnDisk = true
            confirmedOnDisk = true
            adopt(reportedSessionId: reported)
            // it also names the model the CLI actually resolved, dated id and
            // all, which is the only way to know it when the dial said "default"
            if ContextWindow.shortName(for: model) != nil { adoptModel(model) }
            becomeReadyIfSpawning()
        case .status:
            spontaneousIfIdle()
        case .streamEvent:
            // text/thinking deltas never reach here — the pump coalesces them
            // into applyPump; what's left is block/message chatter worth an
            // idle check and nothing more
            spontaneousIfIdle()
        case .assistant(let blocks, let usage):
            spontaneousIfIdle()
            // held, not published: finishTurn publishes the last one (D-perf —
            // the context meter is a turn-boundary value, not a live gauge).
            //
            // Not while draining. A reset or a /resume mid-turn supersedes the
            // conversation, sets .draining and terminates — but the dying
            // process's stdout is still arriving, and the reader drains it in
            // full before processExited moves the state on. So every buffered
            // event from a superseded process is seen in exactly this state, and
            // its token counts describe a transcript that is already off screen.
            // (A lens/model drain also passes through here, but only from idle,
            // so there is no in-flight turn whose numbers this could cost.)
            if let usage, state != .draining {
                latestUsage = (config.sessionId, usage)
            }
            for case .toolUse(_, let activity) in blocks { setActivity(activity) }
        case .toolResult:
            setActivity(nil)
        case .taskNotification(let id, let status, let summary):
            // the notice row above the spontaneous turn that follows (D3) —
            // one row per task, live, and gone once the task has settled
            noteTask(id: id, text: summary ?? "background task \(status)", settled: Self.hasSettled(status))
            settleAgent(id, status: status, summary: summary)
        case .taskUpdated(let id, let status):
            // no row of its own (the in-turn activity line covers a live task) —
            // but a patch saying "completed" settles a row that's already up
            if let status, Self.hasSettled(status), taskNotice(id) != nil {
                armSweep(id)
            }
            settleAgent(id, status: status, summary: nil)
        case .taskStarted(let id, let description, let subagentType, let taskType):
            // the agents rail: one row per spawn, keyed on the task id the CLI
            // threads through every later event
            guard !id.isEmpty else { break }
            // Only a spawn names a subagent type (or calls itself a local_agent);
            // a long `grep` the CLI backgrounded arrives on this same channel and
            // is not an agent, however much it looks like one from here.
            let kind: SessionAgent.Kind =
                (subagentType != nil || taskType == "local_agent") ? .agent : .command
            if let index = agents.firstIndex(where: { $0.id == id }) {
                agents[index].description = description ?? agents[index].description
                agents[index].agentType = subagentType ?? agents[index].agentType
                agents[index].kind = kind
            } else {
                agents.append(SessionAgent(id: id,
                                           description: description ?? (kind == .agent ? "an agent" : "a command"),
                                           kind: kind,
                                           agentType: subagentType,
                                           status: .running,
                                           summary: nil))
            }
        case .backgroundTasksChanged:
            break
        case .permissionDenied(let tool, _):
            // normally silent: result.permission_denials carries the tally, and a
            // denial the owner just clicked needs no receipt. Degraded ask-first
            // is the exception — nobody was asked, so nobody knows.
            if stdioPromptUnsupported {
                appendNotice("blocked \(tool) — this claude can't ask first")
            }
        case .result(let r):
            finishTurn(r)
        case .controlRequest(let id, let subtype, let toolName, let needsPerson, let raw):
            guard subtype == "can_use_tool" else { break }
            // A tool that only a person can answer is a question, not a
            // permission: same channel, different UI. If the payload doesn't
            // decode into something choosable, it falls through to the broker
            // rather than blocking forever on a card bob can't draw.
            if needsPerson, let asked = SessionQuestion(rawJSON: raw, requestId: id) {
                question = asked
                return
            }
            routeToBroker(requestId: id, toolName: toolName ?? "?", rawJSON: raw)
        case .controlResponse(let id, _):
            // the readiness handshake answered — the process is alive and
            // listening. any response counts, even an error: it spoke.
            if let id, id == handshakeId {
                handshakeId = nil
                becomeReadyIfSpawning()
            }
            // interrupt acks need no handling — the aborted result does it
        case .rateLimit(let type, let resetsAt, let overage):
            // the subscription is one account's, not this session's, so the
            // numbers go to the one meter the whole window reads. The wire knows
            // the reset instant before the endpoint does; the percentages still
            // come from the endpoint, on a coalesced refresh.
            UsageMeter.shared.nudge(type: type, resetsAt: resetsAt, isUsingOverage: overage)
        case .ignored:
            break
        }
    }

    /// The id the CLI says this process is on, which bob follows if it isn't the
    /// one bob asked for.
    ///
    /// Today it always is: `--resume <id>` appends to that same conversation, and
    /// three transcripts here — 40 days, 9 days, 3 days — were resumed many times
    /// over with the id and the `parentUuid` chain intact. But a CLI that *forked*
    /// a resumed conversation onto a fresh id would leave bob holding the pre-fork
    /// one: the tab's turns would land in a file bob never names again, the state
    /// file would restore the stale head, and the conversation would come back
    /// missing everything said after the first resume. One assignment, and that
    /// whole class of bug can't happen — a session is whatever the CLI says it is.
    private func adopt(reportedSessionId reported: String) {
        guard let id = UUID(uuidString: reported), id != config.sessionId else { return }
        config.sessionId = id
        onConversationChanged?()
    }

    /// One doorway for "this session is running that model": the caption's word
    /// and the context meter's denominator can never disagree.
    private func adoptModel(_ model: String?) {
        let short = ContextWindow.shortName(for: model)
        if short != modelShortName { modelShortName = short }
        contextWindow = ContextWindow.size(for: model)
    }

    private func becomeReadyIfSpawning() {
        guard state == .spawning else { return }
        watchdog?.cancel()
        watchdog = nil
        state = .idle
        note(.activityChanged)
        flushClientQueue()
    }

    /// A turn began that bob didn't start: the CLI re-invoked the model on a
    /// background-task notification (probe 1.2 — THE CRUX). While idle there
    /// is never a send pending — send() flips state before returning.
    private func spontaneousIfIdle() {
        guard state == .idle else { return }
        beginTurn(source: .spontaneous)
    }

    private func beginTurn(source: TurnSource) {
        let entry = TranscriptEntry(role: .bob, text: "")
        transcript.append(entry)
        currentBob = entry
        unspoken = ""
        state = .turnActive(source)
        note(.turnBegan)
    }

    private func finishTurn(_ r: TurnResult) {
        lastResult = r
        publishContextUse()
        let interrupted = state == .interrupting || r.terminalReason == "aborted_streaming"
        if let entry = currentBob {
            transcript.set(activity: nil, of: entry)
            if entry.text.isEmpty, let text = r.text, !text.isEmpty, !r.isError {
                // synthetic turns (/context, slash commands) stream no deltas;
                // the result event carries their whole reply (probe 1.3)
                transcript.set(text: text, of: entry)
                if config.voiced { unspoken = text }
            }
            if interrupted {
                // aborted is not an error — the owner asked for it (edge 4)
                let tail = entry.text.isEmpty ? "(interrupted)" : " (interrupted)"
                transcript.append(text: tail, to: entry)
                if config.voiced { unspoken += tail }
            }
            flushSpeakable(final: true)
            transcript.finalize(entry)
        }
        if r.isError && !interrupted {
            lastError = r.text ?? "claude returned \(r.subtype ?? "an error")"
        }
        currentBob = nil
        unspoken = ""

        switch state {
        case .turnActive, .interrupting:
            break
        default:
            return   // stray result while draining/idle — entry closed, state untouched
        }
        note(.turnEnded)
        if !interrupted, cliQueuedSends > 0 {
            // a send queued in the CLI mid-turn becomes the next turn
            // immediately (probe 1.7) — pre-label it so the incoming events
            // aren't mistaken for a spontaneous turn
            cliQueuedSends -= 1
            beginTurn(source: .user)
        } else {
            // after an interrupt the CLI's queue fate is ambiguous
            // (still_queued) — go idle; if a queued turn does start, the
            // spontaneous path catches and renders it
            cliQueuedSends = 0
            state = .idle
            afterIdle()
        }
    }

    /// A different conversation is in this tab now (reset, or a /resume): the old
    /// one's context number describes nothing on screen. Blank until the new
    /// thread takes its first turn.
    private func forgetContextUse() {
        latestUsage = nil
        if contextUsedPct != nil { contextUsedPct = nil }
    }

    /// The context meter, once per turn. Clamped at 100: the CLI compacts around
    /// the ceiling and a turn straddling that moment can report more than the
    /// window holds, which would read as a bug rather than as "full".
    ///
    /// The conversation check is the second half of the staleness guard: a
    /// trailing `result` from a superseded process still reaches finishTurn, and
    /// a number measured in a thread this tab has since left must not be
    /// published under the one now on screen.
    private func publishContextUse() {
        guard let latest = latestUsage,
              latest.conversation == config.sessionId,
              contextWindow > 0
        else { return }
        // A session holding more than its assumed window IS a long-context
        // session — the API would have refused the prompt otherwise. Promote
        // the denominator; never demote.
        if latest.tokens.contextInUse > contextWindow { contextWindow = 1_000_000 }
        let pct = min(100, Double(latest.tokens.contextInUse) / Double(contextWindow) * 100)
        if contextUsedPct != pct { contextUsedPct = pct }
    }

    /// Client-side queue drains the moment a fresh process reports in (D4):
    /// first queued send starts a turn, the rest ride the CLI's own queue.
    private func flushClientQueue() {
        guard !clientQueue.isEmpty else {
            afterIdle()
            return
        }
        writeUserMessage(clientQueue.removeFirst())
        beginTurn(source: .user)
        for prompt in clientQueue {
            writeUserMessage(prompt)
            cliQueuedSends += 1
        }
        clientQueue.removeAll()
    }

    private func afterIdle() {
        guard state == .idle else { return }
        var wantsDrain = false
        if let change = pendingPromptChange {
            pendingPromptChange = nil
            config.appendSystemPrompt = change
            wantsDrain = true
        }
        if pendingModelDrain {
            pendingModelDrain = false
            wantsDrain = true
        }
        if wantsDrain { beginDrain() }
    }

    private func beginDrain() {
        guard process != nil else { return }
        state = .draining
        closeStdin()   // clean stdin close exits the process (probe 1.1)
    }

    // MARK: - transcript + speech (D5)

    private func appendDelta(_ text: String) {
        guard !text.isEmpty, let entry = currentBob else { return }
        transcript.append(text: text, to: entry)
        if config.voiced { unspoken += text }
        flushSpeakable()
    }

    private func setActivity(_ activity: String?) {
        guard let entry = currentBob else { return }
        transcript.set(activity: activity, of: entry)
    }

    private func appendNotice(_ text: String) {
        transcript.append(TranscriptEntry(role: .notice, text: text))
        note(.activityChanged)   // a permanent notice is session health — listeners re-read status
    }

    // MARK: - task notices (live status, not history)

    /// A watcher the owner started and killed shouldn't leave a dim row in the
    /// thread forever, so task chatter gets exactly one row per task: written
    /// once, rewritten as the task talks, swept `taskNoticeLinger` after it
    /// settles. Everything else appendNotice writes is permanent.
    private func noteTask(id: String, text: String, settled: Bool) {
        taskSweeps.removeValue(forKey: id)?.cancel()
        if let entry = taskNotice(id) {
            transcript.set(text: text, of: entry)
        } else {
            transcript.append(TranscriptEntry(role: .notice, text: text, taskId: id))
        }
        if settled { armSweep(id) }
    }

    private func armSweep(_ id: String) {
        taskSweeps.removeValue(forKey: id)?.cancel()
        let linger = taskNoticeLinger
        taskSweeps[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, linger) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.sweepTask(id)
        }
    }

    private func sweepTask(_ id: String) {
        taskSweeps[id] = nil
        guard let entry = taskNotice(id) else { return }
        transcript.remove(entry)
    }

    private func taskNotice(_ id: String) -> TranscriptEntry? {
        transcript.entries.first { $0.taskId == id }
    }

    private func cancelSweeps() {
        for sweep in taskSweeps.values { sweep.cancel() }
        taskSweeps.removeAll()
    }

    /// Notifications only fire when a task is done with something (probe 1.2 saw
    /// "completed"), so anything unrecognized counts as settled; the explicitly
    /// in-flight words are the exception that keeps a row up.
    private static func hasSettled(_ status: String) -> Bool {
        !["running", "in_progress", "pending", "queued", "started", "active"]
            .contains(status.lowercased())
    }

    /// Emit any newly-completed sentences to `onSentence`. Voiced deltas
    /// mirror into `unspoken`; complete sentences leave it, the fragment
    /// stays — no index survives a mutation. A sentence ends at . ? ! or
    /// newline followed by whitespace or end. Runs once per coalesced flush.
    private func flushSpeakable(final: Bool = false) {
        guard config.voiced, onSentence != nil, !unspoken.isEmpty else { return }

        var lastBoundary = unspoken.startIndex
        var i = unspoken.startIndex
        while i < unspoken.endIndex {
            let ch = unspoken[i]
            let next = unspoken.index(after: i)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                if next == unspoken.endIndex || unspoken[next].isWhitespace {
                    lastBoundary = next
                }
            }
            i = next
        }
        if final { lastBoundary = unspoken.endIndex }

        guard lastBoundary > unspoken.startIndex else { return }
        let chunk = String(unspoken[..<lastBoundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        unspoken = String(unspoken[lastBoundary...])
        if !chunk.isEmpty { onSentence?(chunk) }
    }

    // MARK: - stdin

    private func writeUserMessage(_ prompt: String) {
        writeLine(["type": "user", "message": ["role": "user", "content": prompt]])
    }

    private func writeLine(_ object: [String: Any]) {
        guard let stdin = stdinPipe?.fileHandleForWriting,
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)
        // a dead pipe throws; the termination handler owns recovery
        try? stdin.write(contentsOf: data)
    }

    private func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    // MARK: - permissions (phase 3 seam)

    private func routeToBroker(requestId: String, toolName: String, rawJSON: String) {
        // the CLI blocks the turn while the ask is open (probe 1.6) — state stays
        // turnActive, so the tab keeps its working dot while the card waits
        let ask = PermissionRequest(requestId: requestId, sessionId: id,
                                    sessionName: config.name, toolName: toolName,
                                    rawJSON: rawJSON)
        Task { [weak self] in
            guard let self else { return }
            let decision = await self.broker.decide(ask)
            self.answer(ask, decision)
        }
    }

    /// Answer the question claude is blocked on. `choices` maps each question's
    /// text to the labels picked for it; the CLI wants the original input echoed
    /// back with those answers folded in, under an `allow`.
    func answerQuestion(_ choices: [String: [String]]) {
        guard let asked = question else { return }
        writeLine([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": asked.id,
                "response": ["behavior": "allow",
                             "updatedInput": asked.updatedInput(answers: choices)],
            ],
        ])
        question = nil
    }

    /// Hand the decision back. Denying an AskUserQuestion doesn't kill the turn:
    /// the model reads the message in place of an answer and carries on, which is
    /// the closest thing to "you pick" that the protocol has.
    func declineQuestion() {
        guard let asked = question else { return }
        writeLine([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": asked.id,
                "response": ["behavior": "deny",
                             "message": "the owner didn't pick — use your own judgement and say what you chose"],
            ],
        ])
        question = nil
    }

    /// Move an agent row to its ending. Unknown ids are ignored: a task that
    /// never announced a start has no row to settle.
    private func settleAgent(_ id: String, status: String?, summary: String?) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        let settled = SessionAgent.status(from: status)
        if settled.isFinished { agents[index].status = settled }
        if let summary, !summary.isEmpty {
            agents[index].summary = summary.split(separator: "\n").first.map(String.init) ?? summary
        }
    }

    /// The reply the CLI is blocking on. Deny carries a message the model reads
    /// in place of the tool result — verified against 2.1.228: the tool does not
    /// run, `result.permission_denials` names it, the model quotes the message,
    /// and the session takes the next turn normally.
    private func answer(_ ask: PermissionRequest, _ decision: PermissionDecision) {
        let payload: [String: Any]
        switch decision {
        case .allow:
            payload = allowPayload(ask, adopting: [])
        case .allowAdopting(let suggestions):
            payload = allowPayload(ask, adopting: suggestions)
        case .deny(let message):
            payload = ["behavior": "deny", "message": message]
        }
        writeLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": ask.requestId, "response": payload],
        ])
    }

    /// Allow echoes the tool's own input back as `updatedInput` (probe 1.6 — the
    /// field exists so a broker can rewrite arguments; bob only ever agrees). An
    /// ask whose input didn't decode gets no field at all: `{}` would run the
    /// tool with its arguments erased. `updatedPermissions` hands the CLI's own
    /// suggestion back when the owner said "always" — 2.1.228 acts on it (one ask
    /// covered three writes), so the asking really does stop.
    private func allowPayload(_ ask: PermissionRequest,
                              adopting suggestions: [PermissionSuggestion]) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "allow"]
        if let input = ask.input { payload["updatedInput"] = input }
        if !suggestions.isEmpty { payload["updatedPermissions"] = suggestions.map(\.fields) }
        return payload
    }

    // MARK: - forensics

    /// Undecodable stdout lines land in the shared stderr sink (edge 10) —
    /// same file a curious owner already checks: state/bridge-stderr.log.
    /// Written straight from the reader: a diagnostic never wakes the main actor.
    private nonisolated static func noteForensic(_ line: String, name: String, sink: FileHandle) {
        let entry = "[bob:\(name)] undecodable stream line: \(line.prefix(2000))\n"
        if let data = entry.data(using: .utf8) {
            try? sink.write(contentsOf: data)
        }
    }
}
