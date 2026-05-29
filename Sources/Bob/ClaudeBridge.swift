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

    /// bob's most recent reply text (used for text-to-speech).
    var lastResponse: String { turns.last(where: { $0.role == .bob })?.text ?? "" }

    /// Called with each completed sentence as bob streams, so bob can speak as
    /// he thinks rather than reading a finished wall of text. Wired by the view
    /// to VoiceOutput. No-op until set.
    var onSentence: ((String) -> Void)?
    private var spokenUpTo: Int = 0

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
        turns = []
        lastError = nil
        isStreaming = false
        spokenUpTo = 0
    }

    /// A minion bob dispatched just finished — let bob debrief you in his own
    /// voice as a normal bob turn (no "you" turn, since you didn't just ask).
    /// Skipped if bob's mid-reply so it never clobbers a live answer.
    func debrief(task: String, detail: String, ok: Bool) {
        guard !isStreaming else { return }
        let prompt = """
        [system note — not from pawan] a minion you dispatched just finished.
        task: "\(task)"
        outcome: \(ok ? "succeeded" : "failed")
        result: "\(detail)"
        tell pawan in ONE short lowercase line, in your voice, like a bro who just got it done. no preamble, no "the minion" — just say what happened. under 16 words.
        """
        send(prompt, hidden: true)
    }

    func send(_ rawPrompt: String, hidden: Bool = false) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        currentProcess?.terminate()
        lastError = nil
        isStreaming = true
        spokenUpTo = 0
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
        let sessionArgs: [String] = sessionStarted
            ? ["--resume", sessionId]
            : ["--session-id", sessionId]
        process.arguments = [
            "-p",
        ] + sessionArgs + [
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
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
            }
        }

        do {
            try process.run()
            currentProcess = process
            // After a successful spawn, any future turn should resume the session.
            sessionStarted = true
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

    /// Emit any newly-completed sentences (since `spokenUpTo`) to `onSentence`.
    /// A sentence ends at . ? ! or newline followed by whitespace or end.
    private func flushSpeakable(_ full: String, final: Bool = false) {
        guard onSentence != nil else { return }
        let chars = Array(full)
        guard spokenUpTo < chars.count else { return }

        var lastBoundary = spokenUpTo
        var i = spokenUpTo
        while i < chars.count {
            let ch = chars[i]
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let nextIsBreak = (i + 1 >= chars.count) || chars[i + 1].isWhitespace
                if nextIsBreak { lastBoundary = i + 1 }
            }
            i += 1
        }
        // On the final flush, speak whatever's left even without a terminator.
        if final { lastBoundary = chars.count }

        guard lastBoundary > spokenUpTo else { return }
        let chunk = String(chars[spokenUpTo..<lastBoundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        spokenUpTo = lastBoundary
        if !chunk.isEmpty { onSentence?(chunk) }
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
