import Foundation
import Combine

/// bob's mouth. Since P2b this is a command/status facade: message content
/// lives in a TranscriptStore — the companion session's own store once
/// attached — and the bridge publishes only the low-frequency surface
/// (activeLens, lastError, isStreaming) plus which store to read. The old
/// one-shot implementation is still here as `sendLegacy` — reachable by flag,
/// taken automatically for the rest of the run if the streaming session ever
/// falls over (plan D7), and writing into the SAME store, so nothing above
/// this file knows which path is live.
@MainActor
final class ClaudeBridge: ObservableObject {
    /// The conversation on stage. Starts as the bridge's own (the pure-legacy
    /// path writes here); `attach` swaps in the live session's store — a rare
    /// publish, and on fallback the dead session's store is kept so the turns
    /// already on screen stay.
    @Published private(set) var transcript = TranscriptStore()
    @Published var isStreaming: Bool = false
    @Published var lastError: String? = nil

    /// The lens riding on this session — `"music"`, `"project:webapp"`, or nil for
    /// none. Set by typing `@<name>` in the input bar and sticky until `@none` or
    /// a session reset: a lens is a *mode*, not a one-shot. On the streaming path
    /// it rides the process's system prompt (swapped by a graceful respawn), so
    /// re-sending `@music` after editing the file is what picks up the edit.
    @Published var activeLens: String? = nil

    /// bob's most recent reply text (used for text-to-speech).
    var lastResponse: String { transcript.entries.last(where: { $0.role == .bob })?.text ?? "" }

    /// Called with each completed sentence as bob streams, so bob can speak as
    /// he thinks rather than reading a finished wall of text. Wired by the view
    /// to VoiceOutput. No-op until set. Forwarded to the live session, which
    /// owns the sentence flushing on the streaming path.
    var onSentence: ((String) -> Void)? {
        didSet { session?.onSentence = onSentence }
    }
    private var spokenIndex: String.Index?

    /// Minion debriefs waiting to be spoken — queued so none is lost when bob
    /// happens to be mid-reply (or when two minions finish at once).
    private var pendingDebriefs: [(task: String, detail: String, ok: Bool)] = []

    /// Session UUID for this bob launch — the ONE id both paths use, so a
    /// fallback mid-conversation resumes the same CLI session file instead of
    /// starting a stranger. Lowercased because that's what ClaudeSession passes
    /// and the transcript is named after the literal string.
    private(set) var sessionId: String = UUID().uuidString.lowercased()
    /// True once the CLI has actually created that session on disk. First
    /// legacy turn of a fresh id uses `--session-id` (creates); every later one
    /// uses `--resume` (continues).
    private var sessionStarted: Bool = false

    private var currentProcess: Process?

    // MARK: - streaming plumbing

    /// The companion session this bridge mirrors (SessionManager's session #0).
    private var session: ClaudeSession?
    private var mirrors: Set<AnyCancellable> = []
    private var managerWatch: AnyCancellable?
    /// Lens spec last pushed at the process — lets a direct `activeLens = x`
    /// (today's CenterStage) still land at the next send.
    private var pushedLens: String?
    /// The prompt whose turn hasn't finished yet. If the session dies on it,
    /// this is what the legacy path re-sends (D7).
    private var pendingPrompt: String?
    /// One-way door: once the streaming path has failed, the rest of the run is
    /// legacy. A relaunch (or a flag flip) is how you get back.
    private var fellBack = false

    /// P1c makes the persistent session the default. Back to the old one-shot
    /// path with `defaults write app.bob.mac bob.streamingSession -bool false`.
    /// Registration is a default, not a write — the owner's explicit choice
    /// always wins. `SessionManager.streamingFlagKey` is the same string.
    nonisolated static let registerDefaults: Void = {
        UserDefaults.standard.register(defaults: ["bob.streamingSession": true])
    }()

    /// Reads the flag *after* making sure the default-true registration has
    /// run, whatever order the app happens to touch things in.
    static var streamingEnabled: Bool {
        _ = registerDefaults
        return SessionManager.streamingEnabled
    }

    /// True while messages should go down the live process's stdin.
    private var useStreaming: Bool { Self.streamingEnabled && !fellBack }

    init() {
        _ = Self.registerDefaults
        guard Self.streamingEnabled else { return }
        // the companion may already be up (BobApp spawns it post-bootstrap) or
        // may still be waiting on ~/bob — either way, attach the moment it
        // appears so a spontaneous turn can render before the owner has typed
        // anything at all.
        attach(SessionManager.shared.companion)
        managerWatch = SessionManager.shared.$sessions.sink { [weak self] sessions in
            let companion = sessions.first
            Task { @MainActor in self?.attach(companion) }
        }
        // belt and braces on the launch race: BobApp's spawn-at-launch may read
        // the flag before this file's default registration ran, in which case
        // it no-oped. Calling it again once ~/bob is real is free (it guards on
        // companion == nil) and keeps the cold start off the first message.
        Task { @MainActor [weak self] in
            for _ in 0..<100 {
                if BobHome.shared.isInitialized { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            SessionManager.shared.launchCompanionIfEnabled()
            self?.attach(SessionManager.shared.companion)
        }
    }

    /// Mirror a session's transcript and state onto the published surface.
    private func attach(_ candidate: ClaudeSession?) {
        guard useStreaming, let live = candidate, live !== session else { return }
        mirrors.removeAll()
        session = live
        // both paths must name the same conversation (D7) — adopt the session's
        // id, whoever minted it
        sessionId = live.config.sessionId.uuidString.lowercased()
        sessionStarted = live.lastResult != nil || live.transcript.entries.contains { $0.role == .bob }
        live.onSentence = onSentence

        // @Published fires on willSet from the main actor, so these run inline
        // and in order — the new value arrives as the argument, never by
        // re-reading the property.
        live.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.mirror(state) }
        }.store(in: &mirrors)
        live.$lastError.sink { [weak self] error in
            MainActor.assumeIsolated { if let error { self?.lastError = error } }
        }.store(in: &mirrors)

        transcript = live.transcript
        mirror(live.state)
        syncLens(to: live, force: true)
    }

    private func detach() {
        mirrors.removeAll()
        managerWatch = nil
        session = nil
    }

    private func mirror(_ state: ClaudeSession.State) {
        let streaming: Bool
        switch state {
        case .turnActive, .interrupting: streaming = true
        default: streaming = false
        }
        if isStreaming != streaming { isStreaming = streaming }

        if case .failed(let reason) = state {
            fallBackToLegacy(reason)
            return
        }
        if case .idle = state {
            pendingPrompt = nil
            // a debrief that arrived while bob was replying can fire now
            drainDebriefs()
        }
    }

    /// Bring the companion up if nothing has yet — the launch wiring might not
    /// have fired (or ~/bob only just became real). Cold start costs this first
    /// message ~8s, exactly like the legacy path did every message.
    private func ensureCompanion() -> ClaudeSession? {
        if let session { return session }
        guard useStreaming else { return nil }
        let manager = SessionManager.shared
        if let companion = manager.companion {
            attach(companion)
            return session
        }
        attach(manager.spawn(SessionConfig(
            // the id legacy would have used, so a later fallback is seamless
            sessionId: UUID(uuidString: sessionId) ?? UUID(),
            cwd: BobHome.shared.root,
            appendSystemPrompt: activeLens.flatMap { LensStore.shared.resolve($0)?.text },
            permissions: .auto,     // parity with the legacy argv (edge 11)
            name: "bob",
            voiced: true
        )))
        return session
    }

    /// The compatibility door (D7). Spawn threw, the readiness handshake timed
    /// out, or the process died twice in a minute — say so once, quietly, and
    /// finish the run on the path that has always worked. The turns already on
    /// screen stay; the interrupted prompt is re-sent hidden so the owner's
    /// message isn't echoed twice.
    private func fallBackToLegacy(_ reason: String) {
        guard !fellBack else { return }
        fellBack = true
        detach()
        transcript.append(TranscriptEntry(role: .notice, text: "running in compatibility mode"))
        logToSink("streaming session failed (\(reason)) — falling back to the legacy one-shot path")
        isStreaming = false
        if let prompt = pendingPrompt {
            pendingPrompt = nil
            sendLegacy(prompt, hidden: true, useSession: true)
        } else {
            drainDebriefs()
        }
    }

    /// Push the chip's lens onto the process when what it's running differs.
    /// Resolution happens here, per process epoch: same text means no respawn,
    /// edited text means a graceful one (D4).
    private func syncLens(to live: ClaudeSession, force: Bool = false) {
        guard force || pushedLens != activeLens else { return }
        pushedLens = activeLens
        // resolve failure is silent on purpose — LensStore already logged why to
        // state/lens-debug.log, and bob falls through to plain claude
        let text = activeLens.flatMap { LensStore.shared.resolve($0)?.text }
        if text != live.config.appendSystemPrompt {
            live.setAppendSystemPrompt(text)
        }
    }

    // MARK: - public verbs

    /// Start a fresh conversation. Drops continuity with prior turns.
    func resetSession() {
        currentProcess?.terminate()
        currentProcess = nil
        activeLens = nil
        pushedLens = nil
        transcript.replaceAll([])
        lastError = nil
        isStreaming = false
        spokenIndex = nil
        pendingPrompt = nil
        pendingDebriefs.removeAll()
        if useStreaming, let live = session {
            live.reset()            // mints a new id, clears entries + lens
            sessionId = live.config.sessionId.uuidString.lowercased()
        } else {
            sessionId = UUID().uuidString.lowercased()
        }
        sessionStarted = false
    }

    /// Switch the mode bob is in — `@music`, `@project:webapp`, nil for none.
    /// The chip updates now; on the streaming path the process respawns with
    /// the new system prompt while the owner types, and anything sent during
    /// the swap is queued and flushed, never dropped (D4).
    func setLens(_ spec: String?) {
        activeLens = spec
        guard useStreaming, let live = session else {
            // no process yet — the lens rides into the config at spawn
            pushedLens = spec
            return
        }
        // force: re-sending the same @lens is how an edited lens file lands, so
        // always re-resolve; the text comparison inside decides on a respawn
        syncLens(to: live, force: true)
    }

    /// A minion bob dispatched just finished — queue a debrief. It's delivered
    /// when bob isn't mid-reply, so it's never lost in the busy moments. On the
    /// streaming path it folds into bob's own session as a hidden user message
    /// (D3): the prompt never renders, only bob's one-line report.
    func enqueueDebrief(task: String, detail: String, ok: Bool) {
        pendingDebriefs.append((task, detail, ok))
        drainDebriefs()
    }

    private func drainDebriefs() {
        guard !isStreaming, !pendingDebriefs.isEmpty else { return }
        let d = pendingDebriefs.removeFirst()
        let prompt = """
        [system note — not from the user] a minion you dispatched just finished.
        task: "\(d.task)"
        outcome: \(d.ok ? "succeeded" : "failed")
        result: "\(d.detail)"
        tell the user in ONE short lowercase line, in your voice, like a bro who just got it done. no preamble, no "the minion" — just say what happened. under 16 words.
        """
        if useStreaming, let live = ensureCompanion() {
            live.send(prompt, hidden: true, source: .injected)
        } else {
            // legacy debriefs stay ISOLATED one-shots (no --resume) so the
            // synthetic note never pollutes the resumable session
            sendLegacy(prompt, hidden: true, useSession: false)
        }
    }

    func send(_ rawPrompt: String, hidden: Bool = false, useSession: Bool = true) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        if useStreaming, let live = ensureCompanion() {
            lastError = nil
            syncLens(to: live)          // catches a directly-set activeLens
            if !hidden { pendingPrompt = prompt }
            live.send(prompt, hidden: hidden, source: hidden ? .injected : .user)
            return
        }
        sendLegacy(prompt, hidden: hidden, useSession: useSession)
    }

    /// Stop the reply. On the streaming path this is an interrupt control
    /// request — the turn aborts, the process lives (probe 1.4). On the legacy
    /// path it's the old kill.
    func cancel() {
        if useStreaming, let live = session, live.isStreaming {
            live.interrupt()
            return
        }
        currentProcess?.terminate()
    }

    // MARK: - legacy path (one `claude -p` per turn)

    /// Bob's original send: a fresh process per turn, `--resume` for
    /// continuity, stdout streamed straight into the reply. Kept verbatim as
    /// the fallback — same session id as the streaming path, so a conversation
    /// can cross over mid-flight and stay one conversation.
    private func sendLegacy(_ rawPrompt: String, hidden: Bool = false, useSession: Bool = true) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        currentProcess?.terminate()
        lastError = nil
        isStreaming = true
        spokenIndex = nil
        // A hidden turn (e.g. a minion debrief) shows only bob's reply, not the
        // prompt that triggered it.
        if !hidden {
            transcript.append(TranscriptEntry(role: .you, text: prompt))
        }
        transcript.append(TranscriptEntry(role: .bob, text: ""))

        let process = Process()
        let pipe = Pipe()

        // Scrub Claude Code's session env so `claude -p` doesn't see itself
        // as nested inside another session and refuse to start.
        var env = ProcessInfo.processInfo.environment
        for key in [
            "CLAUDECODE",
            "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_SSE_PORT",
            "CLAUDE_CODE_SESSION_ID",
            "CLAUDE_PROJECT_DIR",
        ] {
            env.removeValue(forKey: key)
        }
        // Give the child a real PATH (see spawnPATH) so plugin hooks that
        // shell out to homebrew tools (e.g. node) can find them — doesn't
        // change which `claude` binary we exec, only what its own PATH is.
        env["PATH"] = Self.spawnPATH
        process.environment = env

        // Invoke claude directly, not via login shell. Going through `/bin/zsh -l`
        // resolves PATH via the user's rc files, which can pick up an older
        // homebrew claude that lacks `--permission-mode auto`. Direct invocation
        // pins the newer copy at ~/.local/bin/claude when present.
        process.executableURL = URL(fileURLWithPath: Self.claudePath)
        // First turn: --session-id creates a new session with this UUID.
        // Subsequent turns use --resume. A streaming session that already got
        // as far as creating the file on disk counts as started too — that's
        // what makes the fallback re-send land in the same conversation instead
        // of erroring with "Session ID is already in use".
        // Isolated turns (minion debriefs) carry no session args so they never
        // become part of the resumable conversation.
        let sessionArgs: [String]
        if useSession {
            let started = sessionStarted || Self.sessionExistsOnDisk(sessionId, cwd: BobHome.shared.root)
            sessionArgs = started ? ["--resume", sessionId] : ["--session-id", sessionId]
        } else {
            sessionArgs = []
        }
        // A lens rides on top of the default system prompt, per turn. Resolve
        // failure is silent on purpose — LensStore already logged why to
        // state/lens-debug.log, and we fall through to exactly today's argv.
        // Isolated one-shots (minion debriefs) skip it: they're bob's voice
        // reporting a result, not work done inside a mode.
        var lensArgs: [String] = []
        if useSession, let spec = activeLens, let ctx = LensStore.shared.resolve(spec) {
            lensArgs = ["--append-system-prompt", ctx.text]
        }
        // The one-shot is bob's voice too, so it rides the companion's model
        // choice — the fallback path shouldn't quietly cost a different tier.
        var modelArgs: [String] = []
        if let model = SessionManager.preferredCompanionModel() {
            modelArgs = ["--model", model]
        }
        process.arguments = [
            "-p",
        ] + sessionArgs + lensArgs + [
            // --permission-mode auto engages claude code's classifier: each tool
            // call (Edit, Write, Bash, etc) is judged for safety and auto-allowed
            // when low-risk, blocked when destructive.
            "--permission-mode", "auto",
        ] + modelArgs + [
            prompt
        ]
        // Run claude inside ~/bob/ so it picks up that directory's CLAUDE.md
        // (bob's wiki schema) and `Read`/`Write`/`Edit` operate on the wiki by default.
        process.currentDirectoryURL = BobHome.shared.root
        process.standardOutput = pipe
        // stderr gets its own sink. Sharing stdout's pipe meant the CLI's own
        // noise — hook failures, `node: command not found`, deprecation warnings
        // — arrived mid-sentence inside bob's reply. A file handle also needs no
        // draining, so that channel can never fill up and stall claude.
        process.standardError = Self.stderrSink(root: BobHome.shared.root)

        // Pipe reads break at arbitrary byte boundaries; a multibyte UTF-8
        // sequence (emoji, em-dash) split across two reads would fail to decode
        // and be dropped. Buffer raw bytes and only emit a codepoint-complete
        // prefix, keeping the incomplete tail for the next read.
        var pendingData = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            pendingData.append(chunk)
            let (text, remainder) = Self.decodeUTF8Prefix(pendingData)
            pendingData = remainder
            guard !text.isEmpty else { return }
            Task { @MainActor in
                self?.appendToReply(text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                // speak any trailing fragment that never got a terminator
                if let entry = self.transcript.entries.last(where: { $0.role == .bob }) {
                    self.flushSpeakable(entry.text, final: true)
                }
                self.isStreaming = false
                self.currentProcess = nil
                // a debrief that arrived while bob was replying can fire now
                self.drainDebriefs()
            }
        }

        do {
            try process.run()
            currentProcess = process
            // Only real session turns advance the session; isolated one-shots
            // (debriefs) must not, or the next turn would try to --resume a
            // session that was never created.
            if useSession { sessionStarted = true }
        } catch {
            isStreaming = false
            lastError = "couldn't start claude: \(error.localizedDescription)"
            setReply(lastError ?? "")
        }
    }

    /// Append streamed text to the in-flight bob turn, and speak any sentences
    /// that just completed.
    private func appendToReply(_ text: String) {
        guard let entry = transcript.entries.last(where: { $0.role == .bob }) else { return }
        transcript.append(text: text, to: entry)
        flushSpeakable(entry.text)
    }

    /// Emit any newly-completed sentences (since `spokenIndex`) to `onSentence`.
    /// A sentence ends at . ? ! or newline followed by whitespace or end.
    /// Scans only the unspoken suffix — no O(n) Array copy of the whole reply.
    private func flushSpeakable(_ full: String, final: Bool = false) {
        guard onSentence != nil else { return }
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

    /// Decode the longest valid UTF-8 prefix of `data`, returning the decoded
    /// string and any trailing incomplete-codepoint bytes to retain.
    private nonisolated static func decodeUTF8Prefix(_ data: Data) -> (String, Data) {
        if let s = String(data: data, encoding: .utf8) { return (s, Data()) }
        // A UTF-8 codepoint is at most 4 bytes, so only the last ≤3 can dangle.
        var end = data.count - 1
        let floor = max(0, data.count - 3)
        while end >= floor && end > 0 {
            if let s = String(data: data.subdata(in: 0..<end), encoding: .utf8) {
                return (s, data.subdata(in: end..<data.count))
            }
            end -= 1
        }
        return ("", data)
    }

    /// Replace the in-flight bob turn's text (used for error messages).
    private func setReply(_ text: String) {
        guard let entry = transcript.entries.last(where: { $0.role == .bob }) else { return }
        transcript.set(text: text, of: entry)
    }

    // MARK: - shared plumbing

    /// Does the CLI already have a session file for this id? The transcript
    /// lives at `~/.claude/projects/<cwd-with-slashes-as-dashes>/<id>.jsonl`;
    /// its existence is what decides `--resume` vs `--session-id` when the
    /// streaming path created the session and the legacy path inherits it.
    private nonisolated static func sessionExistsOnDisk(_ id: String, cwd: URL) -> Bool {
        let slug = cwd.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(id).jsonl")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Forensics for the compatibility switch — same log a curious owner
    /// already checks when bob goes quiet.
    private func logToSink(_ line: String) {
        let sink = Self.stderrSink(root: BobHome.shared.root)
        try? sink.write(contentsOf: Data("[bob:bridge] \(line)\n".utf8))
    }

    /// An append handle onto `~/bob/state/bridge-stderr.log` — where every
    /// `claude -p` bob spawns sends its stderr, so chat text is stdout and only
    /// stdout. Opened `O_APPEND` so two claudes writing at once interleave whole
    /// writes instead of clobbering each other, and rotated one generation back
    /// past a megabyte so it can't grow forever. Falls back to /dev/null rather
    /// than ever letting the noise back into the reply.
    nonisolated static func stderrSink(root: URL) -> FileHandle {
        let url = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("bridge-stderr.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            let previous = url.appendingPathExtension("1")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return .nullDevice }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Resolve the claude binary at startup. Prefer `~/.local/bin/claude` (where
    /// recent Claude Code installs land) over older copies that may sit on PATH.
    /// Falls back to PATH lookup via `/usr/bin/env` if no known path is executable.
    /// Internal so MinionService / OpenLine can reuse it. nonisolated so it can
    /// be read from background contexts (minion spawn, open-line generation).
    nonisolated static let claudePath: String = {
        let fm = FileManager.default
        // BOB_CLAUDE_BIN: the bench harness (bench/run.sh) points every claude
        // spawn at a deterministic stand-in. Real installs never set it.
        if let override = ProcessInfo.processInfo.environment["BOB_CLAUDE_BIN"],
           fm.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: let exec find it. If it's missing entirely, Process.run()
        // will throw and ClaudeBridge will surface the error.
        return "/usr/bin/env"
    }()

    /// The PATH every spawned `claude` process should see. Bob launches via
    /// LaunchServices, not an interactive shell, so `ProcessInfo.processInfo
    /// .environment["PATH"]` is launchd's bare default
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) — homebrew tools like `node` aren't on
    /// it, so a claude-side plugin hook that shells out (e.g. the vercel
    /// plugin's SessionEnd hook calling `node`) fails with "command not found"
    /// and that error text leaks into a reply. Resolve the PATH a login shell
    /// would actually have (sources `.zprofile`, where `brew shellenv` usually
    /// lives) once, instead of hardcoding a single homebrew prefix, so this
    /// doesn't rot if tools move. Bounded at 2s in case `.zprofile` hangs;
    /// falls back to a homebrew-prefixed PATH built from the inherited one.
    /// Internal so MinionService / OpenLine / ClaudeSession can reuse it.
    nonisolated static let spawnPATH: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let fallback = "/opt/homebrew/bin:/usr/local/bin:" + inherited

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "echo -n $PATH"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return fallback
        }
        guard done.wait(timeout: .now() + 2) == .success else {
            proc.terminationHandler = nil
            proc.terminate()
            return fallback
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0,
              let resolved = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resolved.isEmpty
        else { return fallback }
        return resolved
    }()
}
