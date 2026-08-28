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
