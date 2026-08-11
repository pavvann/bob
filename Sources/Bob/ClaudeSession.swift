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
    case deny(message: String)
}

/// Ask-first sessions forward can_use_tool requests here; the CLI blocks the
/// turn until a decision comes back. The protocol isolates the blast radius
/// if the hidden stdio flag ever breaks (risk #1).
@MainActor
protocol PermissionBroker {
    func decide(toolName: String, requestJSON: String) async -> PermissionDecision
}

/// The no-op broker phase 1 ships with. The companion runs --permission-mode
/// auto, so this never fires; it exists so the seam is real.
struct AutoAllowBroker: PermissionBroker {
    func decide(toolName: String, requestJSON: String) async -> PermissionDecision { .allow }
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

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
        var hidden: Bool = false      // injected prompts (debriefs) — never rendered
        var activity: String? = nil   // live tool line ("reading Foo.swift") while in flight
    }

    let id = UUID()
    private(set) var config: SessionConfig

    @Published private(set) var state: State = .unspawned
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastResult: TurnResult? = nil

    /// Called with each completed sentence as the reply streams (D5). Only
    /// fires when `config.voiced`. Wired to VoiceOutput by the view layer.
    var onSentence: ((String) -> Void)?
    var broker: PermissionBroker = AutoAllowBroker()

    /// The single derived Bool CenterStage/BobPulse key off (D2).
    var isStreaming: Bool {
        switch state {
        case .turnActive, .interrupting: return true
        default: return false
        }
    }

    /// Most recent completed-or-streaming reply (adapter convenience).
    var lastResponse: String { entries.last(where: { $0.role == .bob })?.text ?? "" }

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
    private var process: Process?
    private var stdinPipe: Pipe?
    private var readerTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var eventTaps: [UUID: AsyncStream<StreamEvent>.Continuation] = [:]

    /// Sends made while no live process could take them (spawning/draining) —
    /// flushed the moment init lands (D4). Nothing is ever silently dropped.
    private var clientQueue: [String] = []
    /// Sends already written to a busy process's stdin; the CLI queues them
    /// natively and runs each as the next turn (probe 1.7).
    private var cliQueuedSends = 0
    /// Index of the in-flight bob entry — deltas append here. Not "last bob
    /// entry": queued user turns may already sit after it.
    private var currentBobIndex: Int?
    private var spokenIndex: String.Index?
    /// A lens change requested mid-turn (D4.2) — `.some(newPrompt)` applies at
    /// the next idle; the prompt itself may be nil (@none).
    private var pendingPromptChange: String?? = nil
    /// False until the CLI confirms the session exists (first init). First
    /// spawn uses --session-id; every respawn uses --resume (D1).
    private var sessionOnDisk = false
    /// request_id of the readiness handshake sent at spawn (see launchProcess).
    private var handshakeId: String?
    private var recentDeaths: [Date] = []
    private var closing = false

    /// `claudePath`/`stderrSink` are injected (SessionManager passes
    /// ClaudeBridge's statics) so the core stays testable standalone.
    init(config: SessionConfig, claudePath: String, stderrSink: FileHandle) {
        self.config = config
        self.claudePath = claudePath
        self.stderrSink = stderrSink
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
        entries.append(Entry(role: .you, text: prompt, hidden: hidden))
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

    /// Hard reset (D1): new conversation id, cleared transcript, lens off.
    /// The old process is torn down immediately and a fresh one spawns with
    /// --session-id.
    func reset() {
        config.sessionId = UUID()
        config.appendSystemPrompt = nil
        sessionOnDisk = false
        entries = []
        lastError = nil
        lastResult = nil
        clientQueue.removeAll()
        cliQueuedSends = 0
        currentBobIndex = nil
        spokenIndex = nil
        pendingPromptChange = nil
        recentDeaths.removeAll()
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
    /// stream. Status derivation and AttentionCenter subscribe here without
    /// touching the state machine.
    var events: AsyncStream<StreamEvent> {
        AsyncStream { continuation in
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
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderrSink

        // stdout → lines → events, in strict order: one detached task frames
        // and decodes off the main actor, then awaits each event into the
        // state machine. AsyncStream buffers unboundedly, so the pipe never
        // backs up against a busy UI.
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
        let reader = Task.detached(priority: .userInitiated) { [weak self] in
            var framer = LineFramer()
            var dropped = 0
            for await chunk in bytes {
                for line in framer.consume(chunk) {
                    let event = StreamJSON.decode(line)
                    if case .ignored(let forensic) = event {
                        if let forensic { await self?.noteForensic(forensic) }
                        continue
                    }
                    await self?.handle(event)
                }
                if framer.droppedLines > dropped {
                    dropped = framer.droppedLines
                    await self?.noteForensic("(dropped oversized stdout line, >4MB)")
                }
            }
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
        case .askFirst:
            args += ["--permission-mode", "manual", "--permission-prompt-tool", "stdio"]
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
        proc.terminate()               // exit handler sees .failed and stays down
    }

    private func processExited(_ proc: Process) {
        guard proc === process else { return }   // stale epoch — ignore
        process = nil
        stdinPipe = nil
        readerTask = nil
        watchdog?.cancel()
        watchdog = nil

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
            respawnAfterUnexpectedDeath()
        case .idle:
            appendNotice("bob's session dropped — reconnecting")
            respawnAfterUnexpectedDeath()
        case .turnActive, .interrupting:
            // mid-turn death: close the in-flight entry and NEVER auto-resend
            // — tools may have half-run (edge 2). CLI-queued sends died with
            // the process; their prompts stay visible for a one-Enter re-send.
            if let idx = currentBobIndex {
                entries[idx].activity = nil
                entries[idx].text += entries[idx].text.isEmpty
                    ? "(connection lost — say that again?)"
                    : " (connection lost — say that again?)"
                flushSpeakable(entries[idx].text, final: true)
            }
            currentBobIndex = nil
            spokenIndex = nil
            cliQueuedSends = 0
            appendNotice("bob's session dropped — reconnecting")
            respawnAfterUnexpectedDeath()
        }
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
            appendNotice("bob's session keeps dying — check state/bridge-stderr.log")
            return
        }
        launchProcess()                // --resume: history survives, same id
    }

    // MARK: - the state machine (D2)

    private func handle(_ event: StreamEvent) {
        broadcast(event)
        switch event {
        case .initialized:
            // init arrives at the start of EVERY turn (never spontaneously at
            // spawn) — it confirms the session file exists, and doubles as a
            // readiness fallback should a future CLI drop the handshake
            sessionOnDisk = true
            becomeReadyIfSpawning()
        case .status:
            spontaneousIfIdle()
        case .streamEvent(let partial):
            spontaneousIfIdle()
            if case .textDelta(let text) = partial { appendDelta(text) }
            // thinking deltas: never spoken, not rendered in v1 (D5)
        case .assistant(let blocks):
            spontaneousIfIdle()
            for case .toolUse(_, let activity) in blocks { setActivity(activity) }
        case .toolResult:
            setActivity(nil)
        case .taskNotification(_, let status, let summary):
            // the notice row above the spontaneous turn that follows (D3)
            appendNotice(summary ?? "background task \(status)")
        case .taskStarted, .taskUpdated, .backgroundTasksChanged:
            break
        case .permissionDenied:
            break   // in-turn auto-denial; result.permission_denials carries the tally
        case .result(let r):
            finishTurn(r)
        case .controlRequest(let id, let subtype, let toolName, let raw):
            guard subtype == "can_use_tool" else { break }
            routeToBroker(requestId: id, toolName: toolName ?? "?", rawJSON: raw)
        case .controlResponse(let id, _):
            // the readiness handshake answered — the process is alive and
            // listening. any response counts, even an error: it spoke.
            if let id, id == handshakeId {
                handshakeId = nil
                becomeReadyIfSpawning()
            }
            // interrupt acks need no handling — the aborted result does it
        case .ignored:
            break
        }
    }

    private func becomeReadyIfSpawning() {
        guard state == .spawning else { return }
        watchdog?.cancel()
        watchdog = nil
        state = .idle
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
        entries.append(Entry(role: .bob, text: ""))
        currentBobIndex = entries.count - 1
        spokenIndex = nil
        state = .turnActive(source)
    }

    private func finishTurn(_ r: TurnResult) {
        lastResult = r
        let interrupted = state == .interrupting || r.terminalReason == "aborted_streaming"
        if let idx = currentBobIndex {
            entries[idx].activity = nil
            if entries[idx].text.isEmpty, let text = r.text, !text.isEmpty, !r.isError {
                // synthetic turns (/context, slash commands) stream no deltas;
                // the result event carries their whole reply (probe 1.3)
                entries[idx].text = text
            }
            if interrupted {
                // aborted is not an error — the owner asked for it (edge 4)
                entries[idx].text += entries[idx].text.isEmpty ? "(interrupted)" : " (interrupted)"
            }
            flushSpeakable(entries[idx].text, final: true)
        }
        if r.isError && !interrupted {
            lastError = r.text ?? "claude returned \(r.subtype ?? "an error")"
        }
        currentBobIndex = nil
        spokenIndex = nil

        switch state {
        case .turnActive, .interrupting:
            break
        default:
            return   // stray result while draining/idle — entry closed, state untouched
        }
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
        if let change = pendingPromptChange {
            pendingPromptChange = nil
            config.appendSystemPrompt = change
            beginDrain()
        }
    }

    private func beginDrain() {
        guard process != nil else { return }
        state = .draining
        closeStdin()   // clean stdin close exits the process (probe 1.1)
    }

    // MARK: - transcript + speech (D5)

    private func appendDelta(_ text: String) {
        guard !text.isEmpty, let idx = currentBobIndex else { return }
        entries[idx].text += text
        flushSpeakable(entries[idx].text)
    }

    private func setActivity(_ activity: String?) {
        guard let idx = currentBobIndex else { return }
        entries[idx].activity = activity
    }

    private func appendNotice(_ text: String) {
        entries.append(Entry(role: .notice, text: text))
    }

    /// Emit any newly-completed sentences (since `spokenIndex`) to
    /// `onSentence`. Moved from ClaudeBridge; deltas arrive as whole strings
    /// now, so the byte-boundary decoding is gone — framing already
    /// guarantees valid UTF-8. A sentence ends at . ? ! or newline followed
    /// by whitespace or end. Scans only the unspoken suffix.
    private func flushSpeakable(_ full: String, final: Bool = false) {
        guard config.voiced, onSentence != nil else { return }
        let start = spokenIndex ?? full.startIndex
        guard start < full.endIndex else { return }

        var lastBoundary = start
        var i = start
        while i < full.endIndex {
            let ch = full[i]
            let next = full.index(after: i)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                if next == full.endIndex || full[next].isWhitespace {
                    lastBoundary = next
                }
            }
            i = next
        }
        if final { lastBoundary = full.endIndex }

        guard lastBoundary > start else { return }
        let chunk = String(full[start..<lastBoundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        spokenIndex = lastBoundary
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
        // the CLI blocks the turn while the request is open (probe 1.6) —
        // state stays turnActive; phase 3's UIPermissionBroker shows the card
        Task { [weak self] in
            guard let self else { return }
            let payload: [String: Any]
            switch await self.broker.decide(toolName: toolName, requestJSON: rawJSON) {
            case .allow:
                payload = ["behavior": "allow"]
            case .deny(let message):
                payload = ["behavior": "deny", "message": message]
            }
            self.writeLine([
                "type": "control_response",
                "response": ["subtype": "success", "request_id": requestId, "response": payload],
            ])
        }
    }

    // MARK: - forensics

    /// Undecodable stdout lines land in the shared stderr sink (edge 10) —
    /// same file a curious owner already checks: state/bridge-stderr.log.
    private func noteForensic(_ line: String) {
        let entry = "[bob:\(config.name)] undecodable stream line: \(line.prefix(2000))\n"
        if let data = entry.data(using: .utf8) {
            try? stderrSink.write(contentsOf: data)
        }
    }
}
