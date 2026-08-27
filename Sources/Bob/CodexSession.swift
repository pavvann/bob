import Foundation

// MARK: - configuration

struct CodexSessionConfig {
    var cwd: URL
    var name: String                                // tab label / log prefix
    var approvalPolicy: CodexApprovalPolicy = .onRequest
    /// nil means the sane GUI default: writes scoped to this session's own cwd.
    var sandbox: CodexSandboxPolicy? = nil
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

    let id = UUID()
    private(set) var config: CodexSessionConfig
    private(set) var threadId: String?

    /// Message content in its own @Observable store, exactly as claude
    /// sessions do it: a streamed token wakes the one row reading it and the
    /// @Published surface below speaks only at boundaries.
    let transcript = TranscriptStore()

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
        switch state {
        case .unspawned, .failed:
            state = .spawning
            Task { await boot() }
        default:
            break
        }
    }

    func send(_ rawText: String, source: TurnSource = .user) {
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
        guard let thread = threadId, let turn = liveTurnId else { return }
        try? await server.interruptTurn(threadId: thread, turnId: turn,
                                        timeout: CodexServer.quiesceTimeout)
    }

    /// This tab is going away: leave nothing of it running, push the pump's
    /// tail out, and stop receiving. The thread itself survives on disk —
    /// that's what makes it resumable.
    ///
    /// Detaching alone would strand it: the shared server keeps executing the
    /// turn, and its next approval arrives at a route nobody owns, which parks
    /// that thread for good. So the open asks are refused and the live turn is
    /// stopped first, on the same leash shutdown uses.
    func close() async {
        let asks = openRequests
        openRequests.removeAll()
        if blockedOn != nil { blockedOn = nil }
        for ask in asks {
            await server.respond(to: ask.id, code: -32800, message: "bob closed this session")
        }
        await quiesce()
        await pump.finish()
        if let thread = threadId { await server.detach(threadId: thread) }
    }

    // MARK: - thread lifecycle

    private func boot() async {
        do {
            _ = try await server.start()
            let route = CodexThreadRoute(pump: pump, quiesce: { [weak self] in await self?.quiesce() })
            let opened: (threadId: String, model: String?, history: [CodexItem])
            // `threadId` first: when app-server dies this session keeps its
            // thread and its transcript, and `open()` is the retry. Starting a
            // fresh thread there would leave the conversation on screen while
            // the model had none of it.
            if let resume = threadId ?? config.resumeThreadId {
                opened = try await server.resumeThread(
                    resume, approvalPolicy: config.approvalPolicy, route: route)
            } else {
                let started = try await server.startThread(
                    cwd: config.cwd, approvalPolicy: config.approvalPolicy, route: route)
                opened = (started.threadId, started.model, [])
            }
            threadId = opened.threadId
            if model != opened.model { model = opened.model }
            hydrate(opened.history)
            state = .idle
            drain()
        } catch {
            fail(error)
        }
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
            case .other: continue
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

    // MARK: - turn lifecycle

    /// At most one send leaves per call, and never a `turn/start` while a turn
    /// is live — a busy thread merges that into the running turn instead of
    /// refusing it, so mid-turn input goes through `turn/steer` and its
    /// `expectedTurnId` precondition, which fails loudly when it's stale.
    private func drain() {
        guard !queue.isEmpty else { return }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let turnId = try await self.server.startTurn(
                    threadId: thread, text: out.text, clientMessageId: out.clientId,
                    approvalPolicy: self.config.approvalPolicy, sandbox: self.sandbox)
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
        // nothing can answer these any more, and phase 2 must not draw a card
        // whose reply would go nowhere
        openRequests.removeAll()
        if blockedOn != nil { blockedOn = nil }
        if !activeFlags.isEmpty { activeFlags = [] }
        fail(reason: message)
    }

    // MARK: - the stream

    /// The pump's one doorway onto the main actor. Coalesced text lands first,
    /// then the boundary that flushed it — so a window's worth of deltas costs
    /// one transcript mutation, and every item completion, server request,
    /// error and turn end is guaranteed to see the text that preceded it.
    func applyPump(text: String?, boundary: CodexEvent?) {
        if let text { appendDelta(text) }
        if let boundary { handle(boundary) }
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
        case .agentMessageDelta, .unmodeled:
            break   // the classifier already coalesced or dropped these
        }
    }

    private func began(_ item: CodexItem) {
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
        case .other:
            break
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
        case .other:
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
        appendNotice("codex is waiting on \(Self.ask(for: request.method)) — nothing moves until it's answered")
    }

    private func settle(_ request: CodexServerRequest) {
        openRequests.removeAll { $0.id == request.id }
        if blockedOn?.id == request.id { blockedOn = openRequests.first }
    }

    /// A turn that ended while parked leaves its asks unanswerable: app-server
    /// has stopped waiting on them, so a card drawn from one would be stale and
    /// an answer sent for one would name a dead turn.
    private func discardRequests(ofTurn turnId: String) {
        guard openRequests.contains(where: { $0.turnId == turnId }) else { return }
        openRequests.removeAll { $0.turnId == turnId }
        if blockedOn?.turnId == turnId { blockedOn = openRequests.first }
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
        StreamPump(classify: { Self.lane(for: $0) }, deliver: { [weak session] text, boundary in
            await session?.applyPump(text: text, boundary: boundary)
        })
    }

    /// Only assistant text is a firehose; everything the state machine acts on
    /// is a boundary, which is what guarantees pending text lands before an
    /// item completes, before a server request, before an error and before the
    /// turn ends. Reasoning deltas are phase 2's — until then they're chatter
    /// that dies here, off-main.
    static func lane(for event: CodexEvent) -> Lane {
        switch event {
        case .agentMessageDelta(_, let text):
            return text.isEmpty ? .drop : .coalesce(text)
        case .unmodeled:
            return .drop
        default:
            return .boundary
        }
    }
}
