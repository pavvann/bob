import Foundation

/// Watches the codex sessions pawan runs in terminal tabs, the way
/// `SessionWatcher` watches claude's, and publishes the same
/// `SessionWatcher.Session` — so the band, the card, the panel, the feed model
/// and the tailer are all reused rather than rebuilt.
///
/// Codex differs from claude in four ways, and each one shapes this file:
///
/// 1. **One rollout per thread**, at
///    `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`, partitioned by
///    the day the session STARTED. A session opened last week and still being
///    typed into today lives in last week's directory — one on this machine ran
///    seven days and reached 33MB — so "scan today's folder" is wrong in exactly
///    the way mtime is wrong. The scan constructs a bounded window of day paths
///    and lets file mtime do the gating.
/// 2. **No pid registry.** Nothing self-reports busy/waiting/idle, so a codex
///    card has no word beyond "it spoke recently": `.unknown`, the same tier a
///    pre-status claude CLI gets. There is no parked twin either — without a
///    registry there is nothing to know about an idle codex session that a
///    stale transcript doesn't already say.
/// 3. **`originator` is the entrypoint stamp**, the analog of claude's
///    `entrypoint: "sdk-cli"`. `codex-tui` is a terminal session, `codex_exec`
///    is `codex exec` (review gates, worktree agents), and `bob` / `bob-probe`
///    are bob's own hands. Only `codex-tui` earns a card.
/// 4. **`source` is a tagged union, not a string.** A subagent thread spawned
///    BY a tui session is *also* stamped `codex-tui` and carries
///    `source: {subagent: {…}}` where a real session carries `source: "cli"`.
///    On this machine 33 of 45 tui rollouts are subagents, so filtering on
///    originator alone would put three noise cards in the band for every real
///    one. Only a literal `"cli"` is someone sitting in front of a terminal.
@MainActor
final class CodexSessionWatcher: ObservableObject {
    static let shared = CodexSessionWatcher()

    /// The cards in the band.
    @Published private(set) var live: [SessionWatcher.Session] = []

    private var sweepTask: Task<Void, Never>?

    /// Same ceiling `SessionWatcher` uses: a streaming rollout is appended to
    /// dozens of times a second and the walk is not worth repeating faster.
    private nonisolated static let floor: TimeInterval = 3
    /// The safety net, and the clock the freshness window rides on — a session
    /// going quiet produces no filesystem event, so only a tick can retire it.
    private nonisolated static let sweepInterval: UInt64 = 45_000_000_000
    private nonisolated static let liveWindow: TimeInterval = 180
    /// How far back a still-live session may have STARTED. A year of history is
    /// not worth walking on every write; 30 days bounds the probe to at most 30
    /// directories and still covers a session that has been open for weeks.
    private nonisolated static let dayWindow = 30

    private init() {
        DirWatcher.shared.acquire(
            path: Self.root(home: FileManager.default.homeDirectoryForCurrentUser).path,
            id: "codex-session-watcher",
            floor: Self.floor
        ) { [weak self] _ in
            let found = Self.scan()
            Task { @MainActor in self?.publish(found) }
        }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { Self.scan() }.value
                self?.publish(found)
                try? await Task.sleep(nanoseconds: Self.sweepInterval)
            }
        }
    }

    deinit { sweepTask?.cancel() }

    private func publish(_ found: [SessionWatcher.Session]) {
        if live != found { live = found }
    }

    // MARK: - the scan

    nonisolated static func root(home: URL) -> URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private nonisolated static func scan() -> [SessionWatcher.Session] {
        sessions(root: root(home: FileManager.default.homeDirectoryForCurrentUser), now: Date())
    }

    /// `now` is injected so the harness can decide what "recent" means.
    nonisolated static func sessions(root: URL, now: Date) -> [SessionWatcher.Session] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-liveWindow)
        var out: [SessionWatcher.Session] = []

        for dir in dayDirs(root: root, now: now) {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }              // a day with no sessions — most of them
            for file in files where file.pathExtension == "jsonl" {
                // mtime is the cheap gate. Unlike claude's transcripts there is
                // no metadata upsert to lie about it, but the rollout still gets
                // token-count and world-state lines with no conversation in
                // them, so the newest real event decides either way.
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate,
                      mtime > cutoff,
                      let probe = CodexProbe.probe(file),
                      probe.originator == "codex-tui",
                      probe.isInteractive
                else { continue }
                let spoke = probe.lastEventAt ?? mtime
                guard spoke > cutoff else { continue }
                out.append(SessionWatcher.Session(
                    id: probe.threadId ?? file.deletingPathExtension().lastPathComponent,
                    fileURL: file,
                    projectName: probe.cwd.map { ($0 as NSString).lastPathComponent } ?? "codex",
                    cwd: probe.cwd,
                    title: probe.title,
                    gitBranch: probe.gitBranch,
                    lastActivity: spoke,
                    provider: .codex
                ))
            }
        }
        return SessionWatcher.sorted(out)
    }

    /// The last `dayWindow` days as paths, newest first. Constructed rather
    /// than enumerated: three nested `contentsOfDirectory` calls over years and
    /// months would walk the whole archive to reach the handful of days that
    /// can still hold a live session.
    nonisolated static func dayDirs(root: URL, now: Date) -> [URL] {
        let cal = Calendar(identifier: .gregorian)
        var out: [URL] = []
        for back in 0..<dayWindow {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            out.append(root
                .appendingPathComponent(String(format: "%04d", y), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", m), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", d), isDirectory: true))
        }
        return out
    }
}
