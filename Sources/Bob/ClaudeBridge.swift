import Foundation

@MainActor
final class ClaudeBridge: ObservableObject {
    enum Role: String { case you, bob }
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        var text: String
    }

    /// The running conversation for this session — your turns and bob's
    /// streamed replies, in order. Replaces the old single `response` so the
    /// chat history stays visible instead of getting wiped each message.
    @Published private(set) var turns: [Turn] = []
    @Published var isStreaming: Bool = false
    @Published var lastError: String? = nil

    /// The lens riding on this session — `"music"`, `"project:lootgo"`, or nil for
    /// none. Set by typing `@<name>` in the input bar and sticky until `@none` or
    /// a session reset: a lens is a *mode*, not a one-shot. Resolved fresh every
    /// turn, so editing the lens file lands on the very next message.
    @Published var activeLens: String? = nil

    /// bob's most recent reply text (used for text-to-speech).
    var lastResponse: String { turns.last(where: { $0.role == .bob })?.text ?? "" }

    /// Called with each completed sentence as bob streams, so bob can speak as
    /// he thinks rather than reading a finished wall of text. Wired by the view
    /// to VoiceOutput. No-op until set.
    var onSentence: ((String) -> Void)?
    private var spokenIndex: String.Index?

    /// Minion debriefs waiting to be spoken — queued so none is lost when bob
    /// happens to be mid-reply (or when two minions finish at once).
    private var pendingDebriefs: [(task: String, detail: String, ok: Bool)] = []

    /// Session UUID for this bob launch. First turn uses `--session-id` (creates).
    /// Subsequent turns use `--resume <id>` (continues). Reset by quit+relaunch
    /// or by calling `resetSession()`.
    private(set) var sessionId: String = UUID().uuidString
    private var sessionStarted: Bool = false

    private var currentProcess: Process?

    /// Start a fresh conversation. Drops continuity with prior turns.
    func resetSession() {
        currentProcess?.terminate()
        sessionId = UUID().uuidString
        sessionStarted = false
        activeLens = nil
        turns = []
        lastError = nil
        isStreaming = false
        spokenIndex = nil
        pendingDebriefs.removeAll()
    }

    /// A minion bob dispatched just finished — queue a debrief. It's delivered
    /// when bob isn't mid-reply, so it's never lost in the busy moments. Runs
    /// as an ISOLATED one-shot (no --resume) so the synthetic note never
    /// pollutes the resumable session's continuity.
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
        send(prompt, hidden: true, useSession: false)
    }

    func send(_ rawPrompt: String, hidden: Bool = false, useSession: Bool = true) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        currentProcess?.terminate()
        lastError = nil
        isStreaming = true
        spokenIndex = nil
        // A hidden turn (e.g. a minion debrief) shows only bob's reply, not the
        // prompt that triggered it.
        if !hidden {
            turns.append(Turn(role: .you, text: prompt))
        }
        turns.append(Turn(role: .bob, text: ""))

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
        process.environment = env

        // Invoke claude directly, not via login shell. Going through `/bin/zsh -l`
        // resolves PATH via the user's rc files, which can pick up an older
        // homebrew claude that lacks `--permission-mode auto`. Direct invocation
        // pins the newer copy at ~/.local/bin/claude when present.
        process.executableURL = URL(fileURLWithPath: Self.claudePath)
        // First turn: --session-id creates a new session with this UUID.
        // Subsequent turns: --resume continues that session. Using --session-id
        // for every turn errors with "Session ID ... is already in use".
        // Session turns thread through --session-id/--resume for continuity.
        // Isolated turns (minion debriefs) carry no session args so they never
        // become part of the resumable conversation.
        let sessionArgs: [String]
        if useSession {
            sessionArgs = sessionStarted ? ["--resume", sessionId] : ["--session-id", sessionId]
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
        process.arguments = [
            "-p",
        ] + sessionArgs + lensArgs + [
            // --permission-mode auto engages claude code's classifier: each tool
            // call (Edit, Write, Bash, etc) is judged for safety and auto-allowed
            // when low-risk, blocked when destructive.
            "--permission-mode", "auto",
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
                if let idx = self.turns.lastIndex(where: { $0.role == .bob }) {
                    self.flushSpeakable(self.turns[idx].text, final: true)
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
        guard let idx = turns.lastIndex(where: { $0.role == .bob }) else { return }
        turns[idx].text += text
        flushSpeakable(turns[idx].text)
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
        guard let idx = turns.lastIndex(where: { $0.role == .bob }) else { return }
        turns[idx].text = text
    }

    func cancel() {
        currentProcess?.terminate()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
}
