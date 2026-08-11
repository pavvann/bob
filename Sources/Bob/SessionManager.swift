import Foundation

/// Owns every live ClaudeSession. Phase 1 exercises exactly one — the
/// companion (bob himself, session #0) — but the N-session surface is
/// declared now so tabs (phase 2) and the manager layer (phase 3) land
/// without reshaping the substrate.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    /// Feature flag for the persistent-session path. Defaults FALSE — P1c
    /// flips it on with the ClaudeBridge adapter. While false, nothing in
    /// the running app changes.
    static let streamingFlagKey = "bob.streamingSession"
    static var streamingEnabled: Bool {
        UserDefaults.standard.bool(forKey: streamingFlagKey)
    }

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published var activeID: UUID? = nil

    /// bob himself — session #0, spawned at app launch.
    var companion: ClaudeSession? { sessions.first }
    var active: ClaudeSession? { sessions.first(where: { $0.id == activeID }) ?? companion }

    /// Spawn-at-launch entry point — BobApp calls this right after
    /// BobHome.bootstrapIfNeeded (P1d wiring) to hide the ~8s cold start.
    func launchCompanionIfEnabled() {
        guard Self.streamingEnabled, companion == nil else { return }
        spawn(SessionConfig(
            cwd: BobHome.shared.root,
            appendSystemPrompt: nil,    // lenses ride in later via setAppendSystemPrompt
            permissions: .auto,         // behavior parity with today's bridge (edge 11)
            name: "bob",
            voiced: true
        ))
    }

    /// Bring a session up. Work sessions (phase 2) spawn on demand — each is
    /// a ~150–300MB node process, so only the companion is always-on.
    @discardableResult
    func spawn(_ config: SessionConfig) -> ClaudeSession {
        let session = ClaudeSession(
            config: config,
            claudePath: ClaudeBridge.claudePath,
            stderrSink: ClaudeBridge.stderrSink(root: BobHome.shared.root)
        )
        sessions.append(session)
        if activeID == nil { activeID = session.id }
        session.spawn()
        return session
    }

    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].close()
        sessions.remove(at: index)
        if activeID == id { activeID = sessions.first?.id }
    }

    /// App-quit teardown (D1): close every stdin, give the processes 2s to
    /// exit on their own, terminate stragglers. P1d wires this into
    /// applicationShouldTerminate.
    func shutdown() async {
        guard !sessions.isEmpty else { return }
        for session in sessions { session.close() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for session in sessions where session.isRunning { session.terminateNow() }
        sessions.removeAll()
        activeID = nil
    }
}
