import Foundation

// MARK: - provider

/// Which agent is behind a session. Claude is the default and wears no mark:
/// the tab band is tight, and a glyph on every chip would be noise — codex tabs
/// are the ones that need telling apart.
enum SessionProvider: String, Codable, Sendable, Equatable {
    case claude
    case codex

    var glyph: String? { self == .codex ? "circle.hexagongrid" : nil }
}

// MARK: - what a stage needs

/// Where a session is, in the words a view actually branches on.
/// `ClaudeSession.draining` folds into `.busy` — it's a deliberate respawn with
/// a turn's worth of latency, which is all the stage ever said about it — and
/// that fold is what lets codex, which has no per-session process to drain,
/// share the same switch.
enum SessionPhase: Equatable {
    case cold
    case waking
    case idle
    case busy
    case down(String)
}

/// The surface the work stage, the tab chip and the caption read. Two session
/// types, one set of views: anything provider-specific is a property here
/// rather than a second copy of the stage.
@MainActor
protocol StageSession: ObservableObject, Identifiable {
    var id: UUID { get }
    var provider: SessionProvider { get }
    var displayName: String { get }
    var cwd: URL { get }
    var transcript: TranscriptStore { get }
    var isStreaming: Bool { get }
    var phase: SessionPhase { get }
    /// The word under the input bar — claude's tier alias, codex's resolved
    /// model id. nil until something has actually said.
    var modelLabel: String? { get }
    var contextUsedPct: Double? { get }
    /// The two down-casts the shared views need, named rather than guessed at:
    /// the live panel and the resume picker are still claude-shaped (phase 2
    /// gives codex both), and the per-session dial is codex-only.
    var claudeSession: ClaudeSession? { get }
    var codexSession: CodexSession? { get }
    func interrupt()
    /// Bring a down session back. `.down` is retryable on both providers —
    /// codex reaches it whenever app-server dies under a healthy session — so
    /// the stage draws a button rather than a dead end.
    func retry()
}

extension ClaudeSession: StageSession {
    var provider: SessionProvider { .claude }
    var displayName: String { config.name }
    var cwd: URL { config.cwd }
    var modelLabel: String? { modelShortName }
    var claudeSession: ClaudeSession? { self }
    var codexSession: CodexSession? { nil }

    var phase: SessionPhase {
        switch state {
        case .unspawned: return .cold
        case .spawning: return .waking
        case .idle: return .idle
        case .turnActive, .interrupting, .draining: return .busy
        case .failed(let why): return .down(why)
        }
    }

    func retry() { spawn() }
}

extension CodexSession: StageSession {
    var provider: SessionProvider { .codex }
    var displayName: String { config.name }
    var cwd: URL { config.cwd }
    var modelLabel: String? { model }
    var claudeSession: ClaudeSession? { nil }
    var codexSession: CodexSession? { self }

    var phase: SessionPhase {
        switch state {
        case .unspawned: return .cold
        case .spawning: return .waking
        case .idle: return .idle
        case .turnActive, .interrupting: return .busy
        case .failed(let why): return .down(why)
        }
    }

    func retry() { open() }
}

// MARK: - what the ambient layer needs

/// The semantic beat a session emits: turn boundaries and health flips, never
/// anything per token. AttentionCenter listens here instead of
/// `objectWillChange`, so a streaming turn wakes it a handful of times rather
/// than once per delta. Emitted *after* the mutation they describe, so a
/// consumer always reads post-change.
///
/// Shared rather than nested in `ClaudeSession`, because the ambient layer is
/// the one part of bob that must not know which agent is behind a tab.
enum SessionNote: Sendable {
    case turnBegan
    case activityChanged   // a notice landed / readiness moved — status may have changed
    case turnEnded
    case sessionFailed
}

/// The only distinction the ambient layer draws between session states — and it
/// is deliberately NOT `SessionPhase`, which folds `.interrupting` into `.busy`.
/// A turn that ended on its own is news; a turn the owner *stopped* is not, and
/// that difference is the whole reason this enum exists rather than reusing the
/// stage's.
enum AmbientPhase: Equatable {
    case settled     // idle, and up
    case working     // a turn is in flight
    case stopping    // the owner asked it to stop, or the process is being cycled
    case offstage    // cold, waking or down — never one end of a turn boundary
}

/// What the ambient layer reads off a session: digests, `>name` addressing, and
/// anything else that listens rather than renders.
///
/// Deliberately not `StageSession`. That one is a *view's* contract —
/// `ObservableObject`, the two provider down-casts, a retry button — and an
/// existential of it would drag `ObservableObject`'s and `Identifiable`'s
/// associated types along for nothing. This one is class-bound and plain, so
/// `[any AmbientSession]` is just a list, which is exactly what a watch keyed by
/// session id needs. Half the requirements are already satisfied by the
/// `StageSession` conformances above; only the four below are new.
@MainActor
protocol AmbientSession: AnyObject {
    var id: UUID { get }
    var provider: SessionProvider { get }
    var displayName: String { get }
    var cwd: URL { get }
    var transcript: TranscriptStore { get }
    var notes: AsyncStream<SessionNote> { get }
    var ambientPhase: AmbientPhase { get }
    var ambientStatus: SessionStatus { get }
    /// Why it needs a look, in this provider's own evidence. The digest that
    /// quotes it is shared; the evidence cannot be — claude reports an outcome
    /// inside a result envelope, codex reports it on the turn and names its own
    /// parks in `activeFlags`.
    func troubleReason(_ status: SessionStatus) -> String
    /// Why its stopping is worth a line at all.
    func settledReason(_ status: SessionStatus) -> String
}

// MARK: - what `>` can address
//
// Both declarations below are pure and both were written to be checked
// directly. They live here rather than in the input bar that calls them because
// keying tabs by name is provider knowledge — it is the `SessionRef` and
// `SessionProvider` rule — and because the ambient loop this closes (a digest
// naming a session, the owner answering it with `>name`) has to be provable
// without compiling the stage.

/// What `>` can address, and nothing it can address twice.
///
/// A claude tab and a codex tab in the same directory get the same default
/// name, and `>project` taking the first of them means the other is
/// unreachable and `>project!` may stop the wrong one — a silently wrong target
/// is the worst outcome this feature has. So a name shared by two tabs is
/// replaced by `name/claude` and `name/codex`, which leaves the bare name
/// matching neither exactly and both by prefix: ambiguous, which the parser
/// already handles by declining. A unique name is untouched, so `>web` and
/// `>we` stay as terse as they were. Two tabs that still collide after
/// qualification (two claude tabs in same-named directories — true before codex
/// existed) drop out entirely rather than being guessed at.
/// Internal rather than private so the rule can be checked directly, the same
/// reason `SessionDispatch` beside it is.
@MainActor
func dispatchKeys(_ tabs: [SessionRef]) -> [String: SessionRef] {
    var counts: [String: Int] = [:]
    for tab in tabs { counts[tab.name, default: 0] += 1 }
    var keyed: [String: SessionRef] = [:]
    var collided: Set<String> = []
    for tab in tabs {
        let key = counts[tab.name] == 1 ? tab.name : "\(tab.name)/\(tab.provider.rawValue)"
        if keyed[key] != nil { collided.insert(key) } else { keyed[key] = tab }
    }
    for key in collided { keyed[key] = nil }
    return keyed
}

/// The `>` command grammar, mirroring the @lens parse: `>webapp fix the test`
/// sends into the session called webapp, `>webapp! stop, run the tests` stops
/// it first (the ONLY road to an interrupt — never implicit). Names match by
/// unambiguous case-insensitive prefix; an exact name beats a longer cousin.
/// Pure, so the harness can table-test every verdict.
enum SessionDispatch {
    enum Verdict: Equatable {
        /// Not a dispatch at all — no `>` head, `> quoted text`, or a name
        /// with nothing to say after it.
        case none
        /// `>web …` with webapp AND webapi alive — the message travels
        /// verbatim; bob can list what was close.
        case ambiguous([String])
        /// `>zzz …` — no session answers to that; verbatim again.
        case noMatch(String)
        /// The one clean verdict: a full session name, the text, and whether
        /// the bang (stop-first) was on it.
        case send(name: String, text: String, bang: Bool)
    }

    static func parse(_ raw: String, names: [String]) -> Verdict {
        guard raw.hasPrefix(">") else { return .none }
        let body = raw.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        guard !token.isEmpty else { return .none }   // "> a quote" — just words
        let text = String(body.dropFirst(token.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }    // nothing to deliver — words for bob
        var name = token
        var bang = false
        if name.hasSuffix("!") {
            bang = true
            name.removeLast()
        }
        guard !name.isEmpty else { return .none }
        let query = name.lowercased()
        if let exact = names.first(where: { $0.lowercased() == query }) {
            return .send(name: exact, text: text, bang: bang)
        }
        let hits = names.filter { $0.lowercased().hasPrefix(query) }
        switch hits.count {
        case 0: return .noMatch(name)
        case 1: return .send(name: hits[0], text: text, bang: bang)
        default: return .ambiguous(hits)
        }
    }
}

// MARK: - what the picker decides

/// One pick from the "+" picker. A value rather than four arguments, because
/// the provider decides which of the rest even apply.
struct SessionPick {
    var url: URL
    var provider: SessionProvider = .claude
    /// Claude's ask-first hand. On a codex session it reads as `untrusted`
    /// instead — the same gesture, one notch stricter than the default.
    var permissions: PermissionPolicy = .auto
    var model: String? = nil

    /// Codex's approval policy for this pick. `on-request` is the GUI default
    /// and it is only safe because bob now has somewhere to put the question.
    var approvalPolicy: CodexApprovalPolicy {
        permissions == .askFirst ? .untrusted : .onRequest
    }
}

// MARK: - one tab, either provider

/// A session in the band, whichever kind it is. An enum rather than an
/// existential because SwiftUI's `@ObservedObject` needs a concrete type — so
/// the switch happens once at each of the three mount points and the views
/// underneath stay generic.
enum SessionRef: Identifiable {
    case claude(ClaudeSession)
    case codex(CodexSession)

    /// Both sessions' ids are immutable `let`s, so identity — the thing every
    /// `ForEach` and `.animation(value:)` reads — needs no isolation.
    var id: UUID {
        switch self {
        case .claude(let session): return session.id
        case .codex(let session): return session.id
        }
    }

    var provider: SessionProvider {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    @MainActor
    var name: String {
        switch self {
        case .claude(let session): return session.config.name
        case .codex(let session): return session.config.name
        }
    }

    @MainActor
    var cwd: URL {
        switch self {
        case .claude(let session): return session.config.cwd
        case .codex(let session): return session.config.cwd
        }
    }
}
