import Foundation

// MARK: - configuration

struct CodexSessionConfig {
    /// bob's own handle for this tab, kept across relaunches so the state file
    /// doesn't rewrite a fresh id every launch. Unlike claude's `sessionId` it
    /// names nothing on codex's side — the thread id does that.
    var sessionId: UUID = UUID()
    var cwd: URL
    var name: String                                // tab label / log prefix
    var approvalPolicy: CodexApprovalPolicy = .onRequest
    /// nil means the sane GUI default: writes scoped to this session's own cwd.
    var sandbox: CodexSandboxPolicy? = nil
    /// nil = whatever codex's own config resolves. Sent at thread open and on
    /// every turn, so the dial can move mid-conversation.
    var model: String? = nil
    /// nil = the model's own advertised default effort.
    var effort: String? = nil
    /// Names a thread app-server already has, so the first open is a resume.
    var resumeThreadId: String? = nil
}

/// How the last turn ended. The codex analogue of `TurnResult` — narrower,
/// because app-server reports the outcome rather than a closing message.
struct CodexTurnOutcome: Equatable {
    var status: CodexTurnStatus
    var durationMs: Int?
    var error: String?
}

// MARK: - the session

/// One app-server thread and the state machine around it — the peer of
/// `ClaudeSession`, speaking the same state vocabulary so phase 1b's UI is
/// shared rather than forked. The process itself belongs to `CodexServer`,
/// which many of these share.
@MainActor
final class CodexSession: ObservableObject, Identifiable {
    enum TurnSource: Equatable { case user, injected }

    /// `ClaudeSession.State` minus the two cases the protocol has no analogue
    /// for: `.draining` (a per-session process to exit gracefully — codex
    /// sessions share one) and a spontaneous turn source (nothing here
    /// re-invokes the model without bob asking).
    enum State: Equatable {
        case unspawned
        case spawning                 // thread/start or thread/resume in flight
        case idle
        case turnActive(TurnSource)
        case interrupting
        case failed(String)
    }

    /// What closing this tab actually managed to stand down. The two failures
    /// are kept apart because they are different sentences to say to the owner:
    /// one is work that is definitely still running, the other is a turn that
    /// never confirmed it stopped.
    enum CloseOutcome: Equatable {
        case clean
        /// A command was executing when the tab closed. It keeps running until
        /// app-server exits — bob has no way to reap it (phase 0: children
        /// survive `turn/interrupt`, and the process group belongs to the server
        /// every other codex tab is also using).
        case leftCommandRunning
        /// The interrupt went out but `turn/completed` didn't arrive inside the
        /// leash — app-server does not always answer `turn/interrupt` promptly.
        /// Nothing is known to be running; the thread is treated as still live
        /// because assuming otherwise is what strands it.
        case turnDidNotConfirm
    }

    let id = UUID()
    /// Published because the dial draws its own checkmarks from it: the four
    /// settings are bob's, visible, and changed in place.
    @Published private(set) var config: CodexSessionConfig
    private(set) var threadId: String?

    /// This session's config or thread no longer matches what the registry has
    /// on disk. Whoever owns the state file wires this to its write; without it
    /// a relaunch resumes yesterday's thread with today's model.
    var onConfigChanged: (() -> Void)?
    /// Who answers codex's approval requests. The UI broker by default — the
    /// card is the whole reason a GUI can default to `on-request`.
    var broker: PermissionBroker = UIPermissionBroker.shared

    /// Message content in its own @Observable store, exactly as claude
    /// sessions do it: a streamed token wakes the one row reading it and the
    /// @Published surface below speaks only at boundaries.
    let transcript = TranscriptStore()
    /// The typed work codex reports — commands, tools, searches, file changes
    /// and reasoning (#38 T2.3/T2.4). Its own store for the same reason the
    /// transcript has one: a command's output is a firehose, and it must not
    /// come through this object's `objectWillChange`.
    let activity: CodexActivityStore

    @Published private(set) var state: State = .unspawned
    @Published private(set) var lastError: String? = nil
    @Published private(set) var lastTurn: CodexTurnOutcome? = nil
    /// Percentage of the model's window the conversation filled at the end of
    /// the last turn. `modelContextWindow` arrives with the counts, so this
    /// needs no per-model table and no ratchet.
    @Published private(set) var contextUsedPct: Double? = nil
    /// Whatever model app-server resolved for this thread, verbatim.
    @Published private(set) var model: String? = nil
    /// Last turn's counts, published at the boundary with the percentage above
    /// — never on a delta, and never the mid-turn readings.
    @Published private(set) var tokenUsage: CodexTokenUsage? = nil
    /// The oldest request codex is blocked on. Phase 2 draws the card; phase
    /// 1a's job is that the state is visible rather than silent.
    @Published private(set) var blockedOn: CodexServerRequest? = nil
    /// app-server's own read on the thread — `waitingOnApproval` and friends.
    @Published private(set) var activeFlags: [String] = []

    /// The single derived Bool the stage keys off, same shape as claude's.
    var isStreaming: Bool {
        switch state {
        case .turnActive, .interrupting: return true
        default: return false
        }
    }

    private let server: CodexServer
    private lazy var pump: StreamPump<CodexEvent> = .codex(session: self)

    /// THE authoritative answer to "is a turn live". Phase 0 found that a
    /// second `turn/start` on a busy thread is silently MERGED into the
    /// running turn and handed back that turn's id — two prompts fused into
    /// one, no error anywhere — so liveness may never be inferred from the
    /// transcript or from a notification's absence. It is set when a turn id
    /// arrives and cleared only by that turn's `turn/completed`.
    private var liveTurnId: String?
    /// The window between writing `turn/start` and learning its id, in which
    /// there is nothing to steer against and a second `turn/start` would be
    /// the exact mistake above.
    private var turnStarting = false
    /// A `turn/steer` is on the wire and its message is out of the queue.
    private var steerInFlight = false
    private var wantsInterrupt = false
    private var lastCompletedTurnId: String?
    /// The tab is gone. Terminal and one-way: a `thread/start` still in flight
    /// when the owner closes the tab must not be adopted on the way back, or a
    /// prompt queued while it was waking runs for a session the manager and the
    /// UI have already dropped — an invisible turn, with invisible approvals.
    private var isClosed = false
    /// Which thread transition is the live one. Bumped *synchronously* by every
    /// caller that moves this tab between threads — `open`, `retry`, `repoint` —
    /// so anything already in flight learns it has been superseded at its very
    /// next await, instead of finishing and writing its answer over the newer
    /// one. `isClosed` is the same idea with only one destination; this is the
    /// generalisation the resume picker needs, because a `/resume` pick can land
    /// while a restored tab is still booting and both paths write `threadId`.
    private var transition = 0
    /// What app-server resolved for this thread when it opened — the honest
    /// meaning of "auto" once a per-turn override has been applied.
    private var threadDefaultModel: String?
    /// A model or effort override has gone out on this thread, so silence no
    /// longer means "codex's own default".
    private var appliedOverride = false
    /// `commandExecution` items that never reported a terminal state. Phase 0
    /// measured that `turn/interrupt` leaves the spawned process running while
    /// its item reports `failed` / `exitCode: -1`, so this is deliberately NOT
    /// pruned at a turn boundary: it is the only honest answer to "did this tab
    /// start something that can outlive it".
    private var liveCommands: Set<String> = []

    private struct Outbound {
        let text: String
        let clientId: String
        let source: TurnSource
    }

    private struct ItemRow {
        let entry: TranscriptEntry
        let turnId: String
    }

    private var queue: [Outbound] = []
    /// Item rows are NOT dropped when a turn completes: phase 0 watched an
    /// interrupted command's `item/completed` arrive *after* `turn/completed`,
    /// so a late item has to find the row it already owns instead of stranding
    /// one. They're pruned a turn later instead, which is all the slack a late
    /// item needs and the only thing keeping this map bounded.
    private var itemRows: [String: ItemRow] = [:]
    private var currentAgentRow: TranscriptEntry?
    /// Opened when the turn begins and claimed by that turn's first
    /// `agentMessage`. claude sessions put a bob row up the moment you send,
    /// and the stage keys its streaming affordance off one existing — waiting
    /// for codex's first item instead would fork that, and would leave a turn
    /// stopped before it said anything with nowhere to print "(interrupted)".
    private var unclaimedAgentRow: TranscriptEntry?
    /// Rows bob wrote locally on send, waiting for their echo to claim them.
    private var pendingUserRows: [(clientId: String, entry: TranscriptEntry)] = []
    private var openRequests: [CodexServerRequest] = []
    private var latestUsage: CodexTokenUsage?
    private var contextWindow: Int?

    init(config: CodexSessionConfig, server: CodexServer) {
        self.config = config
        self.server = server
        self.activity = CodexActivityStore(scope: config.cwd.path)
    }

    /// Sane GUI default (#37 T1.5): writes scoped to the session's own cwd and
    /// no wider. `dangerFullAccess` isn't representable at all.
    private var sandbox: CodexSandboxPolicy {
        config.sandbox ?? .workspaceWrite(writableRoots: [config.cwd.path])
    }

    // MARK: - public verbs

    /// Open the thread. Idempotent from a settled state; a retry after failure
    /// starts clean.
    func open() {
        guard !isClosed else { return }
        switch state {
        case .unspawned, .failed:
            state = .spawning
            transition += 1
            let mine = transition
            Task { await boot(generation: mine) }
        default:
            break
        }
    }

    func send(_ rawText: String, source: TurnSource = .user) {
        guard !isClosed else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if case .failed(let why) = state {
            lastError = "session is down (\(why))"
            return
        }
        lastError = nil
        let row = TranscriptEntry(role: .you, text: text)
        transcript.append(row)
        let clientId = UUID().uuidString
        pendingUserRows.append((clientId, row))
        // an echo that never comes — a turn stopped before its steer produced
        // an item — must not accumulate; only the binding degrades
        if pendingUserRows.count > 64 { pendingUserRows.removeFirst() }
        queue.append(Outbound(text: text, clientId: clientId, source: source))
        drain()
    }

    /// Stop the live turn. app-server answers `{}` and the turn lands
    /// `interrupted`; the command it spawned may well still be running — only
    /// app-server's own exit reaps those — so this promises the turn stops,
    /// not the work.
    func interrupt() {
        guard let thread = threadId else { return }
        guard let turn = liveTurnId else {
            if turnStarting { wantsInterrupt = true }
            return
        }
        state = .interrupting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.server.interruptTurn(threadId: thread, turnId: turn)
            } catch {
                // a stop that never landed must not leave the tab claiming it
                // did; `turn/completed` still settles the state either way
                self.lastError = Self.reason(error)
            }
        }
    }

    /// Answer a request codex is blocked on. Phase 2 owns the decision shapes;
    /// the id rides back exactly as it arrived.
    func answer(_ request: CodexServerRequest, result: [String: Any]) async {
        await server.respond(to: request.id, result: result)
        settle(request)
    }

    func refuse(_ request: CodexServerRequest, code: Int, message: String) async {
        await server.respond(to: request.id, code: code, message: message)
        settle(request)
    }

    /// Shutdown's hook, called by the server from outside its own isolation so
    /// the reply to this interrupt can still be dispatched while it waits.
    func quiesce() async {
        guard let thread = threadId else { return }
        guard let turn = liveTurnId else {
            // the turn's id hasn't come back yet, so there is nothing to name in
            // an interrupt. Arm it the same way `interrupt()` does and
            // `adoptTurn` stands the turn down the moment the id lands —
            // without this, a close inside that window leaves the turn running
            // and the wait below burns its whole leash.
            if turnStarting { wantsInterrupt = true }
            return
        }
        try? await server.interruptTurn(threadId: thread, turnId: turn,
                                        timeout: CodexServer.quiesceTimeout)
    }

    /// This tab is going away: leave nothing of it *startable*, push the pump's
    /// tail out, and stop receiving. The thread itself survives on disk — that's
    /// what makes it resumable.
    ///
    /// Detaching alone would strand it: the shared server keeps executing the
    /// turn, and its next approval arrives at a route nobody owns, which parks
    /// that thread for good. So the open asks are refused, the queue is dropped
    /// and the live turn is stopped first, on the same leash shutdown uses.
    ///
    /// The outcome is honest rather than reassuring: a command already running
    /// cannot be reaped from here, so a close that leaves one behind says so and
    /// the owner is told.
    @discardableResult
    func close() async -> CloseOutcome {
        isClosed = true
        let (settled, commands) = await standDown(refusing: "bob closed this session")
        await pump.finish()
        guard let thread = threadId else { return .clean }
        await release(thread, settled: settled, commands: commands)
        if commands.isEmpty, settled { return .clean }
        return commands.isEmpty ? .turnDidNotConfirm : .leftCommandRunning
    }

    /// Everything a tab does on its way *off* a thread — whether it is closing or
    /// moving to another one. Both leave a thread app-server keeps executing, and
    /// both have to leave it unable to ask a question nobody will answer. Shared
    /// because it was written twice and the second copy got two of these wrong.
    ///
    /// The order is the whole content of it:
    ///
    ///  - the asks leave `openRequests` **before** the broker is told, which is
    ///    what stops a resumed continuation putting a second answer on the wire.
    ///    `answer(_:choosing:)` proves it by membership, so that removal is the
    ///    proof rather than a courtesy.
    ///  - the broker is told **at all** because the card lives in
    ///    `UIPermissionBroker`, keyed by *session* — and a repoint does not
    ///    change the session. Leaving it there leaves a card for a conversation
    ///    the tab has left, and that card would mask the next approval from the
    ///    thread it moved to. The blanket ("always allow") goes with it: it was
    ///    granted inside a conversation this tab is no longer in.
    ///  - `liveCommands` is snapshotted **before** the interrupt, because an
    ///    interrupted command's item goes terminal within milliseconds while the
    ///    process it spawned keeps running.
    ///
    /// Returns what the caller needs in order to let the thread go safely.
    private func standDown(refusing reason: String) async
        -> (settled: Bool, commands: Set<String>) {
        // a prompt still waiting for the thread to open must never leave: it was
        // typed for the conversation this tab is walking away from
        queue.removeAll()
        pendingUserRows.removeAll()
        let asks = openRequests
        openRequests.removeAll()
        broker.abandon(sessionId: id)
        if blockedOn != nil { blockedOn = nil }
        for ask in asks {
            await server.respond(to: ask.id, code: -32800, message: reason)
        }
        let commands = liveCommands
        await quiesce()
        return (await waitForTurnEnd(), commands)
    }

    /// How a tab lets go of a thread it is leaving.
    ///
    /// Detach only when the turn is known to have stopped **and** nothing it
    /// spawned is still running. Otherwise the thread is *marked* instead: bob
    /// has stopped owning it, so anything it asks from here is refused on
    /// arrival — an approval delivered to a route nobody owns parks that thread
    /// for good, and phase 0 measured that park as permanent.
    ///
    /// An interrupt that never confirmed is exactly as unsafe as a command still
    /// running, and for the same reason: bob does not know the turn stopped, so
    /// it must not assume the thread has gone quiet. Work already running cannot
    /// be reaped from here either way — only app-server's own exit does that,
    /// and that process is shared with every other codex tab.
    ///
    /// Internal rather than private because this rule is the whole of finding
    /// out whether a tab let a thread go safely, and it is checked directly for
    /// all four combinations of its two flags.
    func release(_ thread: String, settled: Bool, commands: Set<String>) async {
        if commands.isEmpty, settled {
            await server.detach(threadId: thread)
        } else {
            await server.abandon(threadId: thread)
        }
    }

    /// Whether the live turn actually went terminal, on shutdown's own leash.
    /// Nothing polls app-server: this watches bob's own state, which only moves
    /// when `turn/completed` arrives.
    private func waitForTurnEnd() async -> Bool {
        guard liveTurnId != nil || turnStarting else { return true }
        let deadline = ContinuousClock().now + CodexServer.quiesceTimeout
        while ContinuousClock().now < deadline {
            if liveTurnId == nil, !turnStarting { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return liveTurnId == nil && !turnStarting
    }

    // MARK: - thread lifecycle

    private func boot(generation: Int) async {
        // BEFORE the RPC, so a repoint whose resume then fails still leaves no
        // rows from the thread this tab used to be on. `threadId` has already
        // been moved by the time a repoint reaches here, and is unchanged on a
        // retry after app-server death — which is exactly the difference the
        // store keys on.
        activity.adopt(thread: threadId ?? config.resumeThreadId)
        do {
            _ = try await server.start()
            guard generation == transition, !isClosed else { return }
            let route = CodexThreadRoute(pump: pump, quiesce: { [weak self] in await self?.quiesce() })
            let opened: (threadId: String, model: String?, history: [CodexItem])
            // `threadId` first: when app-server dies this session keeps its
            // thread and its transcript, and `open()` is the retry. Starting a
            // fresh thread there would leave the conversation on screen while
            // the model had none of it.
            if let resume = threadId ?? config.resumeThreadId {
                opened = try await server.resumeThread(
                    resume, approvalPolicy: config.approvalPolicy,
                    model: config.model, route: route)
            } else {
                let started = try await server.startThread(
                    cwd: config.cwd, approvalPolicy: config.approvalPolicy,
                    model: config.model, route: route)
                opened = (started.threadId, started.model, [])
            }
            // the owner closed the tab while this RPC was in flight. Adopting
            // now would drain the queue into a session nothing on screen owns.
            if isClosed {
                await abandonStartup(opened.threadId)
                return
            }
            // a newer transition took over while this RPC was in flight — a
            // `/resume` pick on a tab that was still waking, or a second pick.
            // Writing now would put the conversation the owner just left back on
            // the tab, and hydrate its history under the wrong thread id.
            //
            // The queue is deliberately NOT dropped here the way `isClosed`
            // drops it: it belongs to whoever superseded us. What does have to go
            // is a thread this boot opened and nobody now owns — an approval from
            // it would reach a route that no longer answers, which parks it.
            if generation != transition {
                if opened.threadId != threadId {
                    await server.abandon(threadId: opened.threadId)
                }
                return
            }
            let isNewThread = threadId != opened.threadId
            threadId = opened.threadId
            // records the id a fresh thread was just given, so the NEXT boot can
            // tell a retry (same thread, keep the rows) from a move (clear them)
            activity.adopt(thread: opened.threadId)
            // the thread id is what a relaunch resumes; it is only ever news
            // once per thread, so this doesn't write on every retry
            if isNewThread {
                onConfigChanged?()
                // named here rather than by the caller: the name needs the
                // thread id, which only exists now
                let name = config.name
                Task { [weak self] in await self?.setName(name) }
            }
            if model != opened.model { model = opened.model }
            threadDefaultModel = opened.model
            hydrate(opened.history)
            state = .idle
            drain()
        } catch {
            // a failure belonging to a superseded transition must not put the tab
            // in `.failed` over a boot that is still going fine
            guard generation == transition, !isClosed else { return }
            fail(error)
        }
    }

    /// A thread that finished opening after its tab was closed. It is nobody's:
    /// the route is refused rather than merely dropped, because a thread whose
    /// requests reach no one parks forever.
    private func abandonStartup(_ thread: String) async {
        queue.removeAll()
        await server.abandon(threadId: thread)
    }

    /// Put a resumed thread's own history on screen. Codex sends it once, in
    /// `thread/resume`'s reply, and never again as notifications — so without
    /// this the model remembers a conversation the transcript can't show, the
    /// same seam the claude side closed in #30.
    ///
    /// Only onto an empty transcript. Recovery after a server death resumes
    /// the same thread with bob's own rows already up, and those are what the
    /// owner actually watched — replaying over them would double every line.
    private func hydrate(_ history: [CodexItem]) {
        guard transcript.entries.isEmpty, !history.isEmpty else { return }
        var rows: [TranscriptEntry] = []
        for item in history {
            let row: TranscriptEntry
            switch item.content {
            case .userMessage(let text, _): row = TranscriptEntry(role: .you, text: text)
            case .agentMessage(let text): row = TranscriptEntry(role: .bob, text: text)
            // a resumed thread's commands and file changes are history, not
            // activity: the gutter answers "what is happening now", and rows for
            // work that finished yesterday would read as if it just ran
            default: continue
            }
            rows.append(row)
            itemRows[item.id] = ItemRow(entry: row, turnId: item.turnId)
        }
        guard !rows.isEmpty else { return }
        transcript.replaceAll(rows)
        for row in rows { transcript.finalize(row) }
        transcript.append(TranscriptEntry(role: .notice,
            text: "resumed this thread — the last \(rows.count) messages, read from codex"))
        // so the first new turn prunes these the way it prunes any other
        // turn's rows, instead of holding them forever
        lastCompletedTurnId = history.last?.turnId
    }

    /// Name the thread so `thread/list` (phase 1b's resume picker) has
    /// something to show besides the first prompt.
    func setName(_ name: String) async {
        guard let thread = threadId else { return }
        try? await server.setThreadName(name, threadId: thread)
    }

    /// Point this tab at another thread app-server already has (`/resume`, #38
    /// T2.6): same tab, same cwd, same dial, different conversation. The peer of
    /// `ClaudeSession.resume`, and of its `reload` — repointing at the thread
    /// this tab is *already* on re-reads that thread instead, which is the only
    /// way a restored tab's own history gets back on screen.
    ///
    /// Leaving a thread is the delicate half, not arriving at one — so the whole
    /// of it is `standDown` and `release`, the same two steps `close()` takes,
    /// rather than a second copy of that reasoning.
    func repoint(to newThreadId: String) {
        guard !isClosed else { return }
        // bumped here, synchronously, rather than inside the task: a boot already
        // in flight has to learn it is stale *now*, or it will finish and write
        // the thread the owner just moved off back onto the tab
        transition += 1
        let mine = transition
        Task { await moveThread(to: newThreadId, generation: mine) }
    }

    private func moveThread(to newThreadId: String, generation: Int) async {
        let leaving = threadId
        let reloading = newThreadId == leaving
        state = .spawning
        let (settled, commands) = await standDown(
            refusing: "bob moved this tab to another thread")
        // superseded mid-teardown: bail without touching `threadId`, so the
        // transition that replaced us still sees the thread we were leaving and
        // releases it itself. Bailing after a partial teardown is safe — every
        // step of it is idempotent, and the newer one repeats all of them.
        guard generation == transition, !isClosed else { return }
        if let leaving, !reloading {
            await release(leaving, settled: settled, commands: commands)
        }
        guard generation == transition, !isClosed else { return }
        // everything below belongs to the thread being left
        liveTurnId = nil
        turnStarting = false
        steerInFlight = false
        wantsInterrupt = false
        lastCompletedTurnId = nil
        itemRows.removeAll()
        currentAgentRow = nil
        unclaimedAgentRow = nil
        liveCommands.removeAll()
        latestUsage = nil
        contextWindow = nil
        if contextUsedPct != nil { contextUsedPct = nil }
        if tokenUsage != nil { tokenUsage = nil }
        if lastTurn != nil { lastTurn = nil }
        if lastError != nil { lastError = nil }
        if !activeFlags.isEmpty { activeFlags = [] }
        // an override is "for this turn and subsequent turns" *on one thread*,
        // so arriving somewhere new means nothing has been applied yet
        appliedOverride = false
        threadDefaultModel = nil
        // hydrate() only fills an empty transcript — that guard is what stops a
        // server-death recovery doubling every line, and it is also what makes
        // clearing here the whole of "show me that conversation instead"
        transcript.replaceAll([])
        threadId = newThreadId
        if config.resumeThreadId != newThreadId {
            config.resumeThreadId = newThreadId
            onConfigChanged?()
        }
        await boot(generation: generation)
        // after boot, not before: hydrate() declines a transcript that already has
        // a row in it, and the picked thread's own history is the point
        guard generation == transition else { return }
        if !commands.isEmpty {
            appendNotice("left \(commands.count) command"
                + "\(commands.count == 1 ? "" : "s") running on the thread you came from"
                + " — codex reaps those when bob quits")
        } else if !settled {
            appendNotice("the turn on the thread you came from never confirmed it stopped"
                       + " — bob left that thread alone rather than reusing it")
        }
    }

    // MARK: - the dial (#37 T1.5)

    /// All four settings are overrides carried on the next `turn/start`, so a
    /// change lands on the next thing you say rather than needing a respawn —
    /// the one thing codex sessions get for free that claude's model swap pays
    /// a drain for.
    func setModel(_ id: String?) {
        guard config.model != id else { return }
        config.model = id
        // the caption follows the choice immediately: the next turn will run it,
        // and app-server only names the model at thread open
        if let resolved = id ?? turnModel ?? threadDefaultModel { model = resolved }
        if let effort = config.effort,
           !CodexCatalog.shared.efforts(for: id).isEmpty,
           !CodexCatalog.shared.efforts(for: id).contains(effort) {
            config.effort = nil     // this model doesn't advertise that one
        }
        onConfigChanged?()
    }

    func setEffort(_ effort: String?) {
        guard config.effort != effort else { return }
        config.effort = effort
        onConfigChanged?()
    }

    /// What "auto" has to put on the wire, and why it can't just be silence.
    ///
    /// `model` and `effort` on `turn/start` are overrides "for this turn **and
    /// subsequent turns**". Once one has been applied, dropping the field stops
    /// saying anything and app-server keeps running the last thing it was told —
    /// so the dial would read auto while the session ran whatever was picked
    /// three turns ago. Auto therefore restores explicitly: the model
    /// app-server itself resolved when the thread opened, and that model's own
    /// advertised default effort. Before any override has been applied there is
    /// nothing to undo and the field stays absent, which is what lets codex's
    /// own config decide on a fresh thread.
    private var turnModel: String? {
        if let picked = config.model { return picked }
        return appliedOverride ? (threadDefaultModel ?? CodexCatalog.shared.defaultModelId) : nil
    }

    private var turnEffort: String? {
        if let picked = config.effort { return picked }
        return appliedOverride ? CodexCatalog.shared.defaultEffort(for: turnModel) : nil
    }

    func setSandbox(_ policy: CodexSandboxPolicy?) {
        guard config.sandbox != policy else { return }
        config.sandbox = policy
        onConfigChanged?()
    }

    func setApprovalPolicy(_ policy: CodexApprovalPolicy) {
        guard config.approvalPolicy != policy else { return }
        config.approvalPolicy = policy
        onConfigChanged?()
    }

    /// What the dial shows for the sandbox — nil in config means the default,
    /// and the default is writes scoped to this session's own cwd.
    var sandboxPolicy: CodexSandboxPolicy { sandbox }

    // MARK: - turn lifecycle

    /// At most one send leaves per call, and never a `turn/start` while a turn
    /// is live — a busy thread merges that into the running turn instead of
    /// refusing it, so mid-turn input goes through `turn/steer` and its
    /// `expectedTurnId` precondition, which fails loudly when it's stale.
    private func drain() {
        guard !isClosed, !queue.isEmpty else { return }
        switch state {
        case .idle:
            // a steer still in flight may yet come back and requeue its
            // message at the head; starting the next one now would send the
            // two in the wrong order
            guard !steerInFlight else { return }
            beginTurn(queue.removeFirst())
        case .turnActive:
            // one steer at a time. Two in flight can reach app-server in
            // either order, and two failures both reinsert at index 0 —
            // which reverses the order they were typed in.
            guard !steerInFlight, let turn = liveTurnId, threadId != nil else { return }
            steerInFlight = true
            steer(queue.removeFirst(), expecting: turn)
        case .interrupting, .unspawned, .spawning, .failed:
            return
        }
    }

    private func beginTurn(_ out: Outbound) {
        guard let thread = threadId else { return }
        state = .turnActive(out.source)
        turnStarting = true
        openAgentRow()
        let model = turnModel
        let effort = turnEffort
        if model != nil || effort != nil { appliedOverride = true }
        Task { [weak self] in
            guard let self else { return }
            do {
                let turnId = try await self.server.startTurn(
                    threadId: thread, text: out.text, clientMessageId: out.clientId,
                    approvalPolicy: self.config.approvalPolicy, sandbox: self.sandbox,
                    model: model, effort: effort)
                self.adoptTurn(turnId)
            } catch {
                self.turnStarting = false
                // the stop the owner asked for during the id's window has
                // nothing left to stop; left armed it would take the *next*
                // turn the moment adoptTurn sees it
                self.wantsInterrupt = false
                // the row bob opened for this turn was never written into and
                // never will be: left up, the NEXT turn reuses it and prints
                // its reply above both the failure and the prompt that earned
                // it. The echo that would have claimed the user's row isn't
                // coming either, and a stale one binds the wrong row later.
                self.closeAgentRow(stopped: false)
                self.pendingUserRows.removeAll { $0.clientId == out.clientId }
                self.lastError = Self.reason(error)
                self.appendNotice("codex couldn't start that turn — \(Self.reason(error))")
                // deliberately not re-draining: a queue that retries itself
                // against a server that just refused would spin
                if case .turnActive = self.state { self.state = .idle }
            }
        }
    }

    private func steer(_ out: Outbound, expecting turn: String) {
        guard let thread = threadId else { return }
        Task { [weak self] in
            guard let self else { return }
            var holdForTurnEnd = false
            do {
                _ = try await self.server.steerTurn(
                    threadId: thread, expectedTurnId: turn, text: out.text,
                    clientMessageId: out.clientId)
            } catch {
                // the turn ended under us — the precondition is exactly what
                // makes that loud. Put the send back at the head, where it
                // still sits in front of anything typed after it.
                self.queue.insert(out, at: 0)
                self.lastError = Self.reason(error)
                // …but if that turn is *still* the live one, it refused the
                // steer on its own account — a turn parked on an unanswered
                // approval is the case — and will refuse an identical one
                // just as fast. Wait for `turn/completed` to drain the queue
                // rather than spinning RPCs against it.
                holdForTurnEnd = self.liveTurnId == turn
            }
            self.steerInFlight = false
            if !holdForTurnEnd { self.drain() }
        }
    }

    /// A turn id can arrive twice — `turn/started` often beats `turn/start`'s
    /// own reply — so everything here is idempotent, and a turn that has
    /// already completed can't be brought back by a late reply.
    private func adoptTurn(_ turnId: String) {
        turnStarting = false
        guard turnId != lastCompletedTurnId else { drain(); return }
        if liveTurnId != turnId {
            liveTurnId = turnId
            itemRows = itemRows.filter { $0.value.turnId == lastCompletedTurnId }
            // this turn owns no diff yet, and the gutter says "this turn"
            activity.beginTurn(turnId)
            if case .turnActive = state {} else { state = .turnActive(.user) }
            openAgentRow()
        }
        if wantsInterrupt { wantsInterrupt = false; interrupt() }
        drain()
    }

    /// `turn/completed` is NOT the last message of a turn. Liveness and the
    /// state machine settle here; the item routing map deliberately does not,
    /// because a late `item/completed` is still on its way.
    private func finishTurn(turnId: String, status: CodexTurnStatus,
                            durationMs: Int?, error: String?) {
        guard liveTurnId == nil || liveTurnId == turnId else { return }
        lastCompletedTurnId = turnId
        lastTurn = CodexTurnOutcome(status: status, durationMs: durationMs, error: error)
        closeAgentRow(stopped: status == .interrupted)
        // the thinking row stops saying "thinking" — it keeps what it said, so
        // the fold is still worth opening after the turn
        activity.endReasoning()
        if status == .failed, let error {
            lastError = error
            appendNotice("codex: \(error)")
        }
        discardRequests(ofTurn: turnId)
        publishContextUse()
        liveTurnId = nil
        state = .idle
        drain()
    }

    /// Settle the row the live turn was writing into. `stopped` appends the
    /// marker; a row bob opened on send that the turn never said a word in is
    /// removed instead of left blank.
    private func closeAgentRow(stopped: Bool) {
        if let row = currentAgentRow {
            transcript.set(activity: nil, of: row)
            if stopped {
                // interrupted is not an error — the owner asked for it
                transcript.append(text: row.text.isEmpty ? "(interrupted)" : " (interrupted)", to: row)
            } else if row.text.isEmpty, row === unclaimedAgentRow {
                // the turn never said a word in the row bob opened for it
                transcript.remove(row)
            }
            transcript.finalize(row)
        }
        unclaimedAgentRow = nil
        currentAgentRow = nil
    }

    /// app-server is gone. Every turn it was running died with it, so the state
    /// has to go terminal here: an active session would otherwise stay
    /// `turnActive` and `isStreaming` forever, and an idle one would look fine
    /// until its next send. `.failed` is the retryable state — `open()` starts
    /// clean from it, and the server relaunches on the next `start()`.
    private func serverDied(_ message: String) {
        liveTurnId = nil
        turnStarting = false
        steerInFlight = false
        wantsInterrupt = false
        closeAgentRow(stopped: true)
        // its exit is exactly what reaps the children a `turn/interrupt` never
        // could, so nothing this session started is running any more
        liveCommands.removeAll()
        activity.endRunning(reason: "app-server died")
        activity.endReasoning()
        // nothing can answer these any more, and a card whose reply would go
        // nowhere is worse than no card
        openRequests.removeAll()
        broker.abandon(sessionId: id)
        if blockedOn != nil { blockedOn = nil }
        if !activeFlags.isEmpty { activeFlags = [] }
        fail(reason: message)
    }

    // MARK: - the stream

    /// The pump's one doorway onto the main actor. Coalesced text lands first,
    /// then the boundary that flushed it — so a window's worth of deltas costs
    /// one transcript mutation, and every item completion, server request,
    /// error and turn end is guaranteed to see the text that preceded it.
    func applyPump(text: String?, keyed: [StreamChunk], boundary: CodexEvent?) {
        if let text { appendDelta(text) }
        for chunk in keyed { route(chunk) }
        if let boundary { handle(boundary) }
    }

    /// One window's coalesced output or reasoning, put where it belongs. The
    /// relative order of reply text and a command's output inside a window is
    /// unobservable — they are different surfaces — so only each key's own
    /// order has to hold, and the pump preserves that.
    private func route(_ chunk: StreamChunk) {
        guard let target = CodexStreamTarget(key: chunk.key) else { return }
        switch target {
        case .commandOutput(let item):
            activity.append(output: chunk.text, toCommand: item)
        case .reasoningSummary(let item, let part):
            activity.append(reasoning: chunk.text, part: part, item: item)
        case .reasoningText(let item):
            activity.append(reasoningText: chunk.text, item: item)
        }
    }

    private func handle(_ event: CodexEvent) {
        switch event {
        case .turnStarted(let turnId):
            adoptTurn(turnId)
        case .turnCompleted(let turnId, let status, let durationMs, let error):
            finishTurn(turnId: turnId, status: status, durationMs: durationMs, error: error)
        case .itemStarted(let item):
            began(item)
        case .itemCompleted(let item):
            completed(item)
        case .tokenUsage(let usage):
            // held, not published: a turn reports several times and only the
            // last one describes the window you're looking at
            latestUsage = usage
            if let window = usage.modelContextWindow { contextWindow = window }
        case .threadStatus(_, let flags):
            if activeFlags != flags { activeFlags = flags }
        case .turnFailed(let message, let willRetry):
            lastError = message
            if !willRetry { appendNotice("codex: \(message)") }
        case .serverExited(let message):
            serverDied(message)
        case .serverRequest(let request):
            park(request)
        case .requestResolved(let requestId):
            resolved(requestId)
        case .reasoningPartAdded(let itemId, let part):
            activity.reserveReasoning(part: part, item: itemId)
        case .turnDiff(let turnId, let tally):
            activity.note(diff: tally, turnId: turnId)
        case .agentMessageDelta, .commandOutputDelta, .reasoningDelta, .unmodeled:
            break   // the classifier already coalesced or dropped these
        }
    }

    private func began(_ item: CodexItem) {
        activity.record(item, done: false)
        switch item.content {
        case .userMessage(let text, let clientId):
            bindUserRow(item, text: text, clientId: clientId)
        case .agentMessage(let text):
            let row: TranscriptEntry
            if let waiting = unclaimedAgentRow {
                unclaimedAgentRow = nil
                row = waiting
                if !text.isEmpty { transcript.set(text: text, of: row) }
            } else {
                row = TranscriptEntry(role: .bob, text: text)
                transcript.append(row)
            }
            itemRows[item.id] = ItemRow(entry: row, turnId: item.turnId)
            currentAgentRow = row
        case .commandExecution:
            // the one item kind whose life outlasts bob's interest in it
            liveCommands.insert(item.id)
        case .mcpToolCall, .webSearch, .fileChange, .reasoning, .other:
            break   // the activity store above owns these
        }
    }

    private func openAgentRow() {
        guard currentAgentRow == nil else { return }
        let row = TranscriptEntry(role: .bob, text: "")
        transcript.append(row)
        currentAgentRow = row
        unclaimedAgentRow = row
    }

    private func completed(_ item: CodexItem) {
        activity.record(item, done: true)
        switch item.content {
        case .userMessage(let text, let clientId):
            bindUserRow(item, text: text, clientId: clientId)
        case .agentMessage(let text):
            let row = itemRows[item.id]?.entry ?? adopt(orphan: item)
            // the item's own text is authoritative, so a dropped delta heals
            // here; the guard keeps the re-parse out of the common case, where
            // the streamed text already matches to the byte
            if row.text != text { transcript.set(text: text, of: row) }
            transcript.finalize(row)
            if currentAgentRow === row { currentAgentRow = nil }
        case .commandExecution:
            liveCommands.remove(item.id)
        case .mcpToolCall, .webSearch, .fileChange, .reasoning, .other:
            break
        }
    }

    /// An `item/completed` for an item bob never saw start — a resumed thread,
    /// or a start that arrived before the route existed.
    private func adopt(orphan item: CodexItem) -> TranscriptEntry {
        let row = TranscriptEntry(role: .bob, text: "")
        transcript.append(row)
        itemRows[item.id] = ItemRow(entry: row, turnId: item.turnId)
        return row
    }

    /// bob already wrote this row when the send left, so the echo binds to it
    /// rather than doubling it. `clientUserMessageId` is what makes the match
    /// exact; an echo bob can't recognise — a resumed thread, someone else's
    /// steer — takes the oldest unclaimed row, and only then a new one.
    private func bindUserRow(_ item: CodexItem, text: String, clientId: String?) {
        guard itemRows[item.id] == nil else { return }
        let match = clientId.flatMap { id in pendingUserRows.firstIndex { $0.clientId == id } }
        let row: TranscriptEntry
        if let match {
            row = pendingUserRows.remove(at: match).entry
        } else if !pendingUserRows.isEmpty {
            row = pendingUserRows.removeFirst().entry
        } else {
            row = TranscriptEntry(role: .you, text: text)
            transcript.append(row)
        }
        itemRows[item.id] = ItemRow(entry: row, turnId: item.turnId)
    }

    /// Deltas append to the row the live `agentMessage` item owns. Coalescing
    /// loses which item each fragment came from, which is safe only because
    /// every item's `item/started` and `item/completed` are boundaries: the
    /// pump flushes the pile before either, so a window can never straddle two
    /// items' text.
    private func appendDelta(_ text: String) {
        guard let row = currentAgentRow else { return }
        transcript.append(text: text, to: row)
    }

    // MARK: - blocked-on

    /// An unanswered approval never expires: phase 0 left one open and the
    /// thread simply parked in `activeFlags: ["waitingOnApproval"]`
    /// indefinitely. bob owns that deadline, and until phase 2 draws the card
    /// the least this can do is say so out loud rather than look hung —
    /// `interrupt()` is the way back out.
    ///
    /// Built from the request and nothing else: `item/tool/requestUserInput`
    /// arrives with no accompanying item, so anything assembled here from
    /// `itemRows` would be empty exactly when it mattered.
    private func park(_ request: CodexServerRequest) {
        openRequests.append(request)
        if blockedOn == nil { blockedOn = request }
        guard let ask = CodexApproval.ask(request, sessionId: id, sessionName: config.name) else {
            // no honest card to draw — `item/tool/requestUserInput` answers a
            // map of question ids, which is phase 2's. Say so out loud, and say
            // what the way out is, rather than parking in silence.
            appendNotice("codex is waiting on \(Self.ask(for: request.method))"
                       + " — bob can't answer that one yet; stop the turn to get out")
            return
        }
        Task { [weak self] in
            guard let broker = self?.broker else { return }
            let decision = await broker.decide(ask)
            await self?.answer(request, choosing: decision)
        }
    }

    /// The owner pressed a button. `.choice` carries the whole reply the
    /// request's own decision list named; anything else means the ask was
    /// withdrawn (its turn died, the session went away) and there is nobody
    /// left to answer — which the openRequests check is what proves.
    private func answer(_ request: CodexServerRequest, choosing decision: PermissionDecision) async {
        guard openRequests.contains(where: { $0.id == request.id }) else { return }
        guard case .choice(let choice) = decision else {
            settle(request)
            return
        }
        await answer(request, result: choice.result)
    }

    private func settle(_ request: CodexServerRequest) {
        openRequests.removeAll { $0.id == request.id }
        if blockedOn?.id == request.id { blockedOn = openRequests.first }
        broker.withdraw(sessionId: id, requestId: CodexApproval.key(request.id))
    }

    /// `serverRequest/resolved` — somebody answered, and it may not have been
    /// bob: two clients can be attached to one thread. Either way the card goes.
    private func resolved(_ id: CodexRequestId) {
        guard let request = openRequests.first(where: { $0.id == id }) else { return }
        settle(request)
    }

    /// A turn that ended while parked leaves its asks unanswerable: app-server
    /// has stopped waiting on them, so a card drawn from one would be stale and
    /// an answer sent for one would name a dead turn.
    private func discardRequests(ofTurn turnId: String) {
        let dead = openRequests.filter { $0.turnId == turnId }
        guard !dead.isEmpty else { return }
        openRequests.removeAll { $0.turnId == turnId }
        if blockedOn?.turnId == turnId { blockedOn = openRequests.first }
        for request in dead {
            broker.withdraw(sessionId: id, requestId: CodexApproval.key(request.id))
        }
    }

    private static func ask(for method: String) -> String {
        switch method {
        case "item/commandExecution/requestApproval": return "permission to run a command"
        case "item/fileChange/requestApproval": return "permission to change files"
        case "item/permissions/requestApproval": return "a permission change"
        case "item/tool/requestUserInput": return "an answer"
        default: return method
        }
    }

    // MARK: - odds and ends

    /// Once per turn, at the boundary — never on a delta.
    private func publishContextUse() {
        guard let usage = latestUsage else { return }
        tokenUsage = usage
        guard let window = contextWindow, window > 0 else { return }
        let pct = min(100, Double(usage.contextInUse) / Double(window) * 100)
        if contextUsedPct != pct { contextUsedPct = pct }
    }

    private func appendNotice(_ text: String) {
        transcript.append(TranscriptEntry(role: .notice, text: text))
    }

    private func fail(_ error: Error) {
        fail(reason: Self.reason(error))
    }

    private func fail(reason why: String) {
        lastError = why
        state = .failed(why)
        appendNotice("codex session is down — \(why)")
    }

    private static func reason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - codex lanes

extension StreamPump where Event == CodexEvent {
    static func codex(session: CodexSession) -> StreamPump<CodexEvent> {
        StreamPump(classify: { Self.lane(for: $0) }, deliver: { [weak session] text, keyed, boundary in
            await session?.applyPump(text: text, keyed: keyed, boundary: boundary)
        })
    }

    /// Three firehoses now, not one: the reply text, a command's output and a
    /// model's reasoning. All three ride the same 16ms window, and everything
    /// the state machine acts on is still a boundary — which is what guarantees
    /// pending text and pending output land before an item completes, before a
    /// server request, before an error and before the turn ends.
    ///
    /// Output and reasoning are keyed rather than joined into the reply: they
    /// land on different surfaces, and one pile would lose which was which.
    static func lane(for event: CodexEvent) -> Lane {
        switch event {
        case .agentMessageDelta(_, let text):
            return text.isEmpty ? .drop : .coalesce(text)
        case .commandOutputDelta(let itemId, let chunk):
            guard !chunk.isEmpty else { return .drop }
            return .coalesceKeyed(key: CodexStreamTarget.commandOutput(item: itemId).key, text: chunk)
        case .reasoningDelta(let itemId, let text, let lane):
            guard !text.isEmpty else { return .drop }
            let target: CodexStreamTarget
            switch lane {
            case .summary(let part): target = .reasoningSummary(item: itemId, part: part)
            case .raw: target = .reasoningText(item: itemId)
            }
            return .coalesceKeyed(key: target.key, text: text)
        case .unmodeled:
            return .drop
        default:
            return .boundary
        }
    }
}
