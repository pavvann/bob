import Foundation

/// Watches `~/.claude/projects/` for the OTHER claude code sessions — the ones
/// pawan runs in terminal tabs — and surfaces recently-active ones as cards
/// beside bob's own minions. A session is "live" while its transcript's newest
/// real event is fresh — mtime alone isn't enough, since claude rewrites the
/// metadata of long-idle transcripts in place. Bob's own spawned runs (chat,
/// minions, open-line) stamp their transcripts `entrypoint: "sdk-cli"` and are
/// filtered out; terminal sessions stamp `"cli"`. All file IO runs off the
/// main actor.
@MainActor
final class SessionWatcher: ObservableObject {
    static let shared = SessionWatcher()

    struct Session: Identifiable, Equatable, Sendable {
        let id: String          // session uuid — the transcript's file stem
        let fileURL: URL
        let projectName: String
        let cwd: String?
        let title: String?
        let gitBranch: String?
        let lastActivity: Date
    }

    @Published private(set) var live: [Session] = []

    private var pollTask: Task<Void, Never>?

    private init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { Self.scan() }.value
                if let self, self.live != found { self.live = found }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    deinit { pollTask?.cancel() }

    private nonisolated static let liveWindow: TimeInterval = 180

    private nonisolated static func scan() -> [Session] {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
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
        // stable order — cards shouldn't shuffle as activity ticks
        return out.sorted {
            $0.projectName == $1.projectName ? $0.id < $1.id : $0.projectName < $1.projectName
        }
    }

    private nonisolated static func fallbackName(for dir: URL) -> String {
        let raw = dir.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return raw.split(separator: "-").last.map(String.init) ?? raw
    }
}
