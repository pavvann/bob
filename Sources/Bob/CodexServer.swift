import Foundation

/// Where one thread's traffic goes. The pump is the session's doorway (text
/// deltas coalesce there, off the main actor); `quiesce` is how shutdown asks
/// that session to stand its live turn down without the server having to hold
/// a second copy of "is a turn live" — that answer lives in CodexSession and
/// nowhere else (phase 0's merge finding).
struct CodexThreadRoute: Sendable {
    let pump: StreamPump<CodexEvent>
    let quiesce: @Sendable () async -> Void
}

enum CodexServerError: Error, LocalizedError {
    case codexMissing
    case notRunning
    case spawnFailed(String)
    case timedOut(method: String)
    case rpc(method: String, code: Int, message: String)
    case malformed(method: String)

    var errorDescription: String? {
        switch self {
        case .codexMissing: return "couldn't find the codex binary"
        case .notRunning: return "codex app-server isn't running"
        case .spawnFailed(let why): return "couldn't start codex app-server: \(why)"
        case .timedOut(let method): return "codex never answered \(method)"
        case .rpc(let method, let code, let message): return "\(method) failed (\(code)): \(message)"
        case .malformed(let method): return "\(method) answered in a shape bob doesn't know"
        }
    }
}

/// What `initialize` told us about the server we're talking to.
struct CodexHandshake: Sendable {
    let userAgent: String
    let codexHome: String
    let platformOs: String
    /// `codex --version`, recorded at spawn so a protocol surprise can be
    /// pinned to a build without asking the user what they have installed.
    let cliVersion: String
    let executablePath: String
}

/// One `codex app-server` process, shared by every codex session in the
/// window. Phase 0 measured 2/4/8 concurrent threads through one server at
/// flat ~33MB RSS with genuinely interleaved turns, so a process per session
/// would buy nothing and cost eight of those.
///
/// The reader frames and decodes off the main actor and hands each event to
/// the owning session's pump; this actor only ever does bookkeeping that
/// cannot suspend on the main actor — otherwise a session blocked on an
/// approval card would wedge every other session's RPCs.
actor CodexServer {
    /// The one server bob runs. Sessions read it from the main actor;
    /// harnesses build their own instance instead.
    @MainActor static let shared = CodexServer(
        executablePath: codexPath,
        stderrSink: ClaudeBridge.stderrSink(root: BobHome.shared.root, name: "codex-stderr.log")
    )

    /// Resolved once and recorded. Unlike `claude`, there is no blessed install
    /// location for codex — npm, homebrew and the managed installer all land it
    /// somewhere different — so the login shell's PATH is searched rather than
    /// guessed at, and a miss is nil so the failure names itself instead of
    /// exec'ing something else. BOB_CODEX_BIN mirrors BOB_CLAUDE_BIN for
    /// harnesses.
    nonisolated static let codexPath: String? = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["BOB_CODEX_BIN"],
           fm.isExecutableFile(atPath: override) {
            return override
        }
        for dir in ClaudeBridge.spawnPATH.split(separator: ":") {
            let candidate = "\(dir)/codex"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()

    private let executablePath: String?
    private let stderrSink: FileHandle

    private var process: Process?
    private var stdin: Pipe?
    private var reader: Task<Void, Never>?
    private var handshake: CodexHandshake?
    private var booting: Task<CodexHandshake, Error>?
    private var hasExited = false

    private var nextId = 1
    private var pending: [CodexRequestId: Waiter] = [:]
    private var routes: [String: CodexThreadRoute] = [:]
    /// Threads whose session closed while work was still running. bob has
    /// stopped owning them, so their requests are refused on arrival — an
    /// approval delivered to no one parks a thread indefinitely, and phase 0
    /// measured that park as permanent.
    private var abandonedThreads: Set<String> = []
    private var taps: [UUID: AsyncStream<CodexEvent>.Continuation] = [:]
    private var exitWait: CheckedContinuation<Bool, Never>?
    private var exitDeadline: Task<Void, Never>?

    private struct Waiter {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let deadline: Task<Void, Never>
        /// Installed the instant the reply names its thread. The reader
        /// dispatches lines strictly in order through one actor call, so
        /// nothing for that thread can slip past between the reply and the
        /// route — which is the whole reason bob doesn't need a buffer for
        /// notifications about a thread it hasn't been told the id of yet.
        let claim: CodexThreadRoute?
    }

    init(executablePath: String?, stderrSink: FileHandle) {
        self.executablePath = executablePath
        self.stderrSink = stderrSink
    }

    // MARK: - lifecycle

    /// Idempotent, and safe to call from several sessions at once — the second
    /// caller waits on the first one's handshake instead of spawning a rival
    /// process.
    func start() async throws -> CodexHandshake {
        if let handshake { return handshake }
        if let booting { return try await booting.value }
        let task = Task { try await launch() }
        booting = task
        do {
            let result = try await task.value
            handshake = result
            booting = nil
            return result
        } catch {
            booting = nil
            throw error
        }
    }

    private func launch() async throws -> CodexHandshake {
        guard let path = executablePath else { throw CodexServerError.codexMissing }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["app-server"]
        // No CODEX_HOME: codex sessions use the global ~/.codex login and
        // config by decision (#35), so the environment is inherited as-is.
        // PATH still needs repairing — bob launches from LaunchServices, and
        // codex shells out to node and git.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeBridge.spawnPATH
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrSink

        let bytes = AsyncStream<Data> { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
        }
        let sink = stderrSink
        let readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            var framer = LineFramer()
            var dropped = 0
            for await chunk in bytes {
                for line in framer.consume(chunk) {
                    let message = CodexJSON.decode(line)
                    if case .undecodable(let raw) = message {
                        Self.note(raw, sink: sink)
                        continue
                    }
                    // routing is actor work and can't suspend; delivery is
                    // awaited out here so a busy main actor never holds the
                    // actor that pending calls need
                    if let (pump, event) = await self?.route(message) {
                        await pump.ingest(event)
                    }
                }
                if framer.droppedLines > dropped {
                    dropped = framer.droppedLines
                    Self.note("(dropped oversized app-server line, >4MB)", sink: sink)
                }
            }
        }

        reader = readerTask

        // Exit runs strictly after the reader has routed every trailing line —
        // an interrupted item's `item/completed` arrives *after*
        // `turn/completed`, and exit handling drops the very routes it needs.
        // Same discipline as ClaudeSession's own exit handler.
        proc.terminationHandler = { [weak self] exited in
            Task {
                _ = await readerTask.value
                await self?.processDidExit(exited)
            }
        }

        do {
            try proc.run()
        } catch {
            reader?.cancel()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexServerError.spawnFailed(error.localizedDescription)
        }
        process = proc
        stdin = stdinPipe
        hasExited = false

        do {
            let result = try await call("initialize", params: [
                "clientInfo": ["name": "bob", "title": "bob", "version": Self.bobVersion],
            ])
            guard let userAgent = result["userAgent"] as? String,
                  let home = result["codexHome"] as? String
            else { throw CodexServerError.malformed(method: "initialize") }
            // no `capabilities`: experimental methods are not something bob wants
            // arriving on a stream it decodes defensively
            notify("initialized", params: [:])

            return CodexHandshake(
                userAgent: userAgent,
                codexHome: home,
                platformOs: (result["platformOs"] as? String) ?? "?",
                cliVersion: Self.recordedVersion(of: path),
                executablePath: path
            )
        } catch {
            // a handshake that never landed leaves a live app-server nobody is
            // talking to: the retry this throw invites would spawn a second one
            // and overwrite the handles, while this process's reader and
            // termination handler stayed alive to clobber the replacement.
            discard(proc, stdinPipe: stdinPipe, stdoutPipe: stdoutPipe)
            throw error
        }
    }

    /// Walk away from a process this actor is giving up on. Clearing `process`
    /// first is what makes the corpse's termination handler a no-op, so the
    /// cleanup happens exactly once and never against a successor.
    private func discard(_ proc: Process, stdinPipe: Pipe, stdoutPipe: Pipe) {
        if proc === process {
            process = nil
            stdin = nil
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        reader?.cancel()
        reader = nil
        try? stdinPipe.fileHandleForWriting.close()
        if proc.isRunning { kill(group: proc) }
    }

    /// Interrupt whatever is live, close stdin, give app-server the ten
    /// seconds it actually wants, then take the process group.
    ///
    /// nonisolated on purpose: the quiesce hooks send `turn/interrupt`, which
    /// is an RPC whose reply the reader has to dispatch — holding the actor
    /// across them would deadlock on the very answers they wait for.
    nonisolated func shutdown() async {
        // Concurrently, and each hook's `turn/interrupt` on a short leash: a
        // quit may not cost the RPC default once per live session on top of
        // the ten-second stdin wait below.
        await withTaskGroup(of: Void.self) { group in
            for quiesce in await quiesceHooks() { group.addTask { await quiesce() } }
        }
        await finishShutdown()
    }

    /// What one quiesce hook may spend waiting for its interrupt's reply.
    /// `turn/interrupt` answers `{}` in milliseconds when app-server is
    /// healthy; when it isn't, shutdown's own ten seconds are the real bound
    /// and this must not eat them.
    static let quiesceTimeout: Duration = .seconds(3)

    private func quiesceHooks() -> [@Sendable () async -> Void] {
        routes.values.map(\.quiesce)
    }

    private func finishShutdown() async {
        guard let proc = process else { return }
        try? stdin?.fileHandleForWriting.close()
        // phase 0: a clean stdin close with work still pending exits 0 in ~9s
        // with children reaped. A ten-second shutdown here is patience, not a
        // hang, and shooting it early is what strands the turn.
        if await awaitExit(within: .seconds(10)) { return }
        kill(group: proc)
    }

    /// Children survive `turn/interrupt` (phase 0 watched a spawned `sleep`
    /// outlive its item), and the npm entry point is a node wrapper, so the
    /// last resort has to take the whole group. macOS's `Process` already
    /// leaves the child leading its own group — measured, pgid == pid — and the
    /// guard means a surprise there can only ever cost this one process rather
    /// than every process bob is in.
    private nonisolated func kill(group proc: Process) {
        let pid = proc.processIdentifier
        guard pid > 0 else { return }
        let pgid = getpgid(pid)
        if pgid == pid, pgid != getpgrp() {
            Darwin.kill(-pgid, SIGKILL)
        } else {
            Darwin.kill(pid, SIGKILL)
        }
    }

    /// Suspends until the process exits or `timeout` passes. Nothing polls:
    /// the termination handler resumes this, and one deadline task resumes it
    /// if app-server is still thinking about it.
    private func awaitExit(within timeout: Duration) async -> Bool {
        if hasExited { return true }
        return await withCheckedContinuation { continuation in
            exitWait = continuation
            exitDeadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.exitWaitExpired()
            }
        }
    }

    private func exitWaitExpired() {
        guard let continuation = exitWait else { return }
        exitWait = nil
        exitDeadline = nil
        continuation.resume(returning: false)
    }

    private func processDidExit(_ exited: Process) {
        guard exited === process else { return }   // a corpse `discard` already buried
        hasExited = true
        exitDeadline?.cancel()
        exitDeadline = nil
        if let continuation = exitWait {
            exitWait = nil
            continuation.resume(returning: true)
        }
        process = nil
        stdin = nil
        reader = nil
        // the cached handshake is per-process: leaving it would make every
        // later start() hand back a handshake for a process that is gone and
        // answer nothing, so nothing would ever relaunch
        handshake = nil
        for waiter in pending.values {
            waiter.deadline.cancel()
            waiter.continuation.resume(throwing: CodexServerError.notRunning)
        }
        pending.removeAll()
        // sessions holding a live turn have no pending call to fail, so they
        // hear about it the same way they hear about everything else
        let orphaned = routes.values.map(\.pump)
        routes.removeAll()
        let event = CodexEvent.serverExited("codex app-server exited")
        Task { for pump in orphaned { await pump.ingest(event) } }
        for tap in taps.values { tap.yield(event) }
    }

    // MARK: - routing

    /// Actor-side bookkeeping for one inbound line, returning the delivery the
    /// reader should await outside this actor. Never suspends.
    private func route(_ message: CodexWireMessage) -> (StreamPump<CodexEvent>, CodexEvent)? {
        switch message {
        case .response(let id, let result):
            guard let waiter = pending.removeValue(forKey: id) else { return nil }
            waiter.deadline.cancel()
            if let claim = waiter.claim,
               let threadId = (result["thread"] as? [String: Any])?["id"] as? String {
                routes[threadId] = claim
                // reopened on purpose: whatever the last tab left running, this
                // owner is here now and its requests are theirs to answer
                abandonedThreads.remove(threadId)
            }
            waiter.continuation.resume(returning: result)
            return nil

        case .failure(let id, let code, let message):
            guard let waiter = pending.removeValue(forKey: id) else { return nil }
            waiter.deadline.cancel()
            waiter.continuation.resume(
                throwing: CodexServerError.rpc(method: waiter.method, code: code, message: message))
            return nil

        case .request(let request):
            // a thread bob walked away from answers for itself, immediately:
            // leaving it parked would cost it every later turn as well
            if let threadId = request.threadId, abandonedThreads.contains(threadId) {
                respond(to: request.id, code: -32800, message: "bob closed this session")
                return nil
            }
            // routed with its id intact and nothing awaited: an approval
            // nobody answers must cost this thread its turn, never the reader
            guard let threadId = request.threadId, let route = routes[threadId] else {
                for tap in taps.values { tap.yield(.serverRequest(request)) }
                return nil
            }
            return (route.pump, .serverRequest(request))

        case .notification(let method, let params, let line):
            let event = CodexJSON.event(method: method, params: params, line: line)
            guard let threadId = CodexJSON.threadId(of: params) else {
                // account-level traffic — rate limits, warnings, login. Phase
                // 2's statusline reads these; no session owns them.
                for tap in taps.values { tap.yield(event) }
                return nil
            }
            guard let route = routes[threadId] else { return nil }
            return (route.pump, event)

        case .undecodable:
            return nil
        }
    }

    /// Notifications no session owns. Each access mints an independent stream;
    /// a tap that stops draining loses its oldest events rather than growing a
    /// queue forever.
    var events: AsyncStream<CodexEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let key = UUID()
            taps[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropTap(key) }
            }
        }
    }

    private func dropTap(_ key: UUID) { taps[key] = nil }

    func detach(threadId: String) { routes[threadId] = nil }

    /// Detach, and refuse anything this thread asks from here on. For a tab that
    /// closed with a command still running: the work cannot be reaped from here
    /// (only app-server's own exit does that, and it is shared), but the thread
    /// must not be able to wedge itself on a question nobody will answer.
    func abandon(threadId: String) {
        routes[threadId] = nil
        abandonedThreads.insert(threadId)
    }

    // MARK: - requests

    /// One outbound request. The timeout exists so a reply that never comes
    /// costs one call rather than wedging the session forever.
    func call(_ method: String, params: [String: Any],
              claiming claim: CodexThreadRoute? = nil,
              timeout: Duration = .seconds(120)) async throws -> [String: Any] {
        guard process != nil else { throw CodexServerError.notRunning }
        let id = CodexRequestId.int(nextId)
        nextId += 1
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id)
            }
            pending[id] = Waiter(method: method, continuation: continuation,
                                 deadline: deadline, claim: claim)
            write(["method": method, "id": id.json, "params": params])
        }
    }

    /// Every list method answers `{data, nextCursor}` and takes `limit` —
    /// phase 0 watched `thread/list` reject `pageSize`, and there is no offset
    /// to page with, so callers walk the cursor from here rather than inventing
    /// arithmetic the protocol doesn't have.
    func page(_ method: String, limit: Int, cursor: String? = nil,
              filters: [String: Any] = [:]) async throws -> (rows: [[String: Any]], nextCursor: String?) {
        var params = filters
        params["limit"] = limit
        if let cursor { params["cursor"] = cursor }
        let result = try await call(method, params: params)
        return (result["data"] as? [[String: Any]] ?? [], result["nextCursor"] as? String)
    }

    /// Answer a server-initiated request. The id is echoed back exactly as it
    /// arrived — it belongs to app-server's numbering, which overlaps bob's.
    func respond(to id: CodexRequestId, result: [String: Any]) {
        write(["id": id.json, "result": result])
    }

    func respond(to id: CodexRequestId, code: Int, message: String) {
        write(["id": id.json, "error": ["code": code, "message": message]])
    }

    private func expire(_ id: CodexRequestId) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CodexServerError.timedOut(method: waiter.method))
    }

    private func notify(_ method: String, params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) {
        guard let handle = stdin?.fileHandleForWriting,
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)
        // a dead pipe throws; the termination handler owns recovery
        try? handle.write(contentsOf: data)
    }

    // MARK: - typed verbs

    func startThread(cwd: URL, approvalPolicy: CodexApprovalPolicy, model: String? = nil,
                     route: CodexThreadRoute) async throws -> (threadId: String, model: String?) {
        var params: [String: Any] = [
            "cwd": cwd.path,
            "approvalPolicy": approvalPolicy.rawValue,
        ]
        // the thread's model, so the caption is right before the first turn has
        // reported anything; `turn/start` carries it again, which is what makes
        // a mid-conversation change take effect
        if let model { params["model"] = model }
        let result = try await call("thread/start", params: params, claiming: route)
        guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
            throw CodexServerError.malformed(method: "thread/start")
        }
        return (id, result["model"] as? String)
    }

    /// The response carries the thread's existing turns — `thread/resume` is
    /// one of the few that populate them — and nothing ever replays them as
    /// notifications, so a caller that drops them has a model remembering a
    /// conversation the screen can't show.
    func resumeThread(_ threadId: String, approvalPolicy: CodexApprovalPolicy,
                      model: String? = nil, route: CodexThreadRoute) async throws
        -> (threadId: String, model: String?, history: [CodexItem]) {
        var params: [String: Any] = [
            "threadId": threadId,
            "approvalPolicy": approvalPolicy.rawValue,
        ]
        if let model { params["model"] = model }
        let result = try await call("thread/resume", params: params, claiming: route)
        guard let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String
        else {
            throw CodexServerError.malformed(method: "thread/resume")
        }
        return (id, result["model"] as? String, CodexJSON.history(of: thread))
    }

    func startTurn(threadId: String, text: String, clientMessageId: String,
                   approvalPolicy: CodexApprovalPolicy,
                   sandbox: CodexSandboxPolicy,
                   model: String? = nil, effort: String? = nil) async throws -> String {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text]],
            "clientUserMessageId": clientMessageId,
            "approvalPolicy": approvalPolicy.rawValue,
            "sandboxPolicy": sandbox.json,
        ]
        // both are overrides "for this turn and subsequent turns" — absent means
        // codex's own config decides, which is what the dial's "auto" means
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        let result = try await call("turn/start", params: params)
        guard let id = (result["turn"] as? [String: Any])?["id"] as? String else {
            throw CodexServerError.malformed(method: "turn/start")
        }
        return id
    }

    /// Mid-turn input. `expectedTurnId` is a precondition, not decoration:
    /// it's what makes a stale send fail loudly instead of fusing two prompts
    /// into one turn the way a second `turn/start` silently would.
    func steerTurn(threadId: String, expectedTurnId: String, text: String,
                   clientMessageId: String) async throws -> String {
        let result = try await call("turn/steer", params: [
            "threadId": threadId,
            "expectedTurnId": expectedTurnId,
            "input": [["type": "text", "text": text]],
            "clientUserMessageId": clientMessageId,
        ])
        return (result["turnId"] as? String) ?? expectedTurnId
    }

    func interruptTurn(threadId: String, turnId: String,
                       timeout: Duration = .seconds(120)) async throws {
        _ = try await call("turn/interrupt",
                           params: ["threadId": threadId, "turnId": turnId],
                           timeout: timeout)
    }

    func setThreadName(_ name: String, threadId: String) async throws {
        _ = try await call("thread/name/set", params: ["threadId": threadId, "name": name])
    }

    func deleteThread(_ threadId: String) async throws {
        _ = try await call("thread/delete", params: ["threadId": threadId])
    }

    // MARK: - forensics

    private nonisolated static func recordedVersion(of path: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "?" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    private nonisolated static var bobVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Undecodable lines land in the log the same way claude's do — written
    /// straight from the reader, so a diagnostic never wakes the main actor.
    private nonisolated static func note(_ line: String, sink: FileHandle) {
        let entry = "[bob:codex] undecodable app-server line: \(line.prefix(2000))\n"
        if let data = entry.data(using: .utf8) { try? sink.write(contentsOf: data) }
    }
}
