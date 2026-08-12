import Foundation

/// Watches the OTHER claude code sessions — the ones pawan runs in terminal
/// tabs — from two vantage points and merges them:
///
/// 1. Transcripts under `~/.claude/projects/` (what a session SAID): a session
///    is transcript-live while its newest real event is fresh. mtime alone is
///    a liar — claude rewrites idle transcripts' metadata in place — so the
///    newest internal event decides.
/// 2. The live-process registry under `~/.claude/sessions/<pid>.json` (what a
///    session IS): pid, cwd, and a self-reported status (busy/waiting/idle).
///    Registry files outlive their processes, so a pid liveness probe gates
///    every record; several pids can share one session id (terminal tabs
///    resuming the same conversation) and collapse to the busiest.
///
/// The tri-state: a session SHOWS if it's transcript-live OR registry-live and
/// working (busy/waiting) — registry status colors the dot either way. A
/// registry-live session that's truly idle is PARKED: counted behind a small
/// disclosure, not a card. Bob's own spawned runs stamp `entrypoint:
/// "sdk-cli"` (transcripts and registry alike) and are filtered out. All file
/// IO runs off the main actor.
@MainActor
final class SessionWatcher: ObservableObject {
    static let shared = SessionWatcher()

    /// What the registry says a session is doing right now. Declaration order
    /// is the dedupe rank: when several pids share one session id, the busiest
    /// wins. `unknown` (no registry record, or a pre-status CLI) sits between
    /// idle and waiting — more alive than a confessed idler, less than a
    /// worker.
    enum ExternalStatus: Int, Comparable, Sendable {
        case idle, unknown, waiting, busy

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        init(registryStatus raw: String?) {
            switch raw {
            case "busy": self = .busy
            case "waiting": self = .waiting
            case "idle": self = .idle
            default: self = .unknown
            }
        }
    }

    struct Session: Identifiable, Equatable, Sendable {
        let id: String          // session uuid — the transcript's file stem
        let fileURL: URL
        let projectName: String
        let cwd: String?
        let title: String?
        let gitBranch: String?
        let lastActivity: Date
        var status: ExternalStatus = .unknown
    }

    /// One `~/.claude/sessions/<pid>.json` record, reduced to what triage
    /// needs. `name` is the CLI's own label for the tab ("lootwalk-37").
    struct RegistryEntry: Equatable, Sendable {
        var pid: Int32
        var sessionId: String
        var cwd: String?
        var entrypoint: String?
        var status: String?
        var statusUpdatedAt: Date?
        var name: String?
    }

    /// The cards in the band.
    @Published private(set) var live: [Session] = []
    /// Idle-but-alive externals — the "3 idle" disclosure, rendered on demand.
    @Published private(set) var parked: [Session] = []

    private var pollTask: Task<Void, Never>?

    private init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { Self.scan() }.value
                if let self {
                    if self.live != found.shown { self.live = found.shown }
                    if self.parked != found.parked { self.parked = found.parked }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    deinit { pollTask?.cancel() }

    private nonisolated static let liveWindow: TimeInterval = 180

    private nonisolated static func scan() -> (shown: [Session], parked: [Session]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return triage(
            transcripts: scanTranscripts(home: home),
            registry: scanRegistry(home: home, alive: isAlive),
            home: home
        )
    }

    // MARK: - transcripts (what a session said)

    private nonisolated static func scanTranscripts(home: URL) -> [Session] {
        let fm = FileManager.default
        let projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        let cutoff = Date().addingTimeInterval(-liveWindow)

        var out: [Session] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // mtime is the cheap gate — it keeps us from probing ~68 dirs of
                // history. But it's a liar on its own: claude upserts metadata
                // into live-but-idle transcripts during config syncs, no content
                // appended, size unchanged. So the newest real event decides.
                // No stamp at all → fall open on mtime rather than vanish.
                guard let mtime = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      mtime > cutoff,
                      let probe = SessionProbe.probe(file),
                      let entrypoint = probe.entrypoint, entrypoint != "sdk-cli"
                else { continue }
                let spoke = probe.lastEventAt ?? mtime
                guard spoke > cutoff else { continue }
                let name = probe.cwd.map { ($0 as NSString).lastPathComponent } ?? fallbackName(for: dir)
                out.append(Session(
                    id: file.deletingPathExtension().lastPathComponent,
                    fileURL: file,
                    projectName: name,
                    cwd: probe.cwd,
                    title: probe.title ?? probe.fallbackTitle,
                    gitBranch: probe.gitBranch,
                    lastActivity: spoke
                ))
            }
        }
        return out
    }

    private nonisolated static func fallbackName(for dir: URL) -> String {
        let raw = dir.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return raw.split(separator: "-").last.map(String.init) ?? raw
    }

    // MARK: - the live-process registry (what a session is)

    /// Every registry record whose process is actually breathing. `alive` is
    /// injected so a harness can decide who lives. sdk-cli records are bob's
    /// own hands and never external cards.
    nonisolated static func scanRegistry(home: URL, alive: (Int32) -> Bool) -> [RegistryEntry] {
        let dir = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [RegistryEntry] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = decodeRegistry(data),
                  entry.entrypoint != "sdk-cli",
                  alive(entry.pid)
            else { continue }
            out.append(entry)
        }
        return out
    }

    /// Defensive by design: a record missing pid or sessionId is skipped, a
    /// missing status decodes as nil (→ .unknown). Timestamps are epoch millis.
    nonisolated static func decodeRegistry(_ data: Data) -> RegistryEntry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = obj["pid"] as? Int,
              let sessionId = obj["sessionId"] as? String, !sessionId.isEmpty
        else { return nil }
        let ms = (obj["statusUpdatedAt"] as? Double) ?? (obj["updatedAt"] as? Double)
        return RegistryEntry(
            pid: Int32(pid),
            sessionId: sessionId,
            cwd: obj["cwd"] as? String,
            entrypoint: obj["entrypoint"] as? String,
            status: obj["status"] as? String,
            statusUpdatedAt: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
            name: obj["name"] as? String
        )
    }

    /// Signal 0 probes a pid without touching it. EPERM still means "someone
    /// lives there" — just not ours to signal.
    nonisolated static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - triage (pure — the harness proves this)

    /// Several terminal tabs can resume one conversation: collapse to one
    /// record per session id, preferring the busiest status; on a tie, the
    /// freshest word.
    nonisolated static func dedupe(_ entries: [RegistryEntry]) -> [String: RegistryEntry] {
        var byId: [String: RegistryEntry] = [:]
        for entry in entries {
            guard let held = byId[entry.sessionId] else {
                byId[entry.sessionId] = entry
                continue
            }
            let challenger = ExternalStatus(registryStatus: entry.status)
            let incumbent = ExternalStatus(registryStatus: held.status)
            if challenger > incumbent ||
                (challenger == incumbent &&
                 (entry.statusUpdatedAt ?? .distantPast) > (held.statusUpdatedAt ?? .distantPast)) {
                byId[entry.sessionId] = entry
            }
        }
        return byId
    }

    /// The tri-state decision. Transcript-live sessions always show — the
    /// registry only colors their dot (a fresh transcript with a confessed
    /// idler behind it decays visibly for the rest of the window instead of
    /// vanishing). Registry-live sessions the transcript hasn't heard from
    /// show while working (busy/waiting) and park when idle. Pure: no clock,
    /// no disk — callers pass pre-filtered inputs.
    nonisolated static func triage(
        transcripts: [Session],
        registry: [RegistryEntry],
        home: URL
    ) -> (shown: [Session], parked: [Session]) {
        let byId = dedupe(registry)
        var shown: [Session] = []
        var parked: [Session] = []
        var seen: Set<String> = []

        for var session in transcripts {
            seen.insert(session.id)
            if let entry = byId[session.id] {
                session.status = ExternalStatus(registryStatus: entry.status)
            }
            shown.append(session)
        }
        for (id, entry) in byId where !seen.contains(id) {
            let session = session(from: entry, home: home)
            switch session.status {
            case .busy, .waiting: shown.append(session)
            case .idle, .unknown: parked.append(session)
            }
        }
        return (sorted(shown), sorted(parked))
    }

    /// A card built from the registry alone — no transcript probe, so it stays
    /// pure. The CLI's own tab label stands in for a title.
    nonisolated static func session(from entry: RegistryEntry, home: URL) -> Session {
        Session(
            id: entry.sessionId,
            fileURL: transcriptURL(sessionId: entry.sessionId, cwd: entry.cwd ?? "", home: home),
            projectName: entry.cwd.map { ($0 as NSString).lastPathComponent } ?? "session",
            cwd: entry.cwd,
            title: entry.name,
            gitBranch: nil,
            lastActivity: entry.statusUpdatedAt ?? .distantPast,
            status: ExternalStatus(registryStatus: entry.status)
        )
    }

    /// Where the CLI writes this session's transcript: the cwd with "/" and
    /// "." dashed becomes the project dir, the session id the file stem —
    /// same encoding ClaudeBridge.sessionExistsOnDisk relies on.
    nonisolated static func transcriptURL(sessionId: String, cwd: String, home: URL) -> URL {
        let slug = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    /// Stable order — cards shouldn't shuffle as activity ticks.
    nonisolated static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.sorted {
            $0.projectName == $1.projectName ? $0.id < $1.id : $0.projectName < $1.projectName
        }
    }
}
