import Foundation

/// Tracks bob's minions — the little agents bob delegates tasks to. Bob is the
/// conductor; minions are the ephemeral hands. Each minion is a JSON record in
/// `~/bob/minions/active/`. When bob delegates a task it writes a record here,
/// updates it as the work progresses, and moves it to `~/bob/minions/done/`
/// when finished. The Swift layer watches the active dir and renders the
/// little agent cards.
@MainActor
final class MinionService: ObservableObject {
    static let shared = MinionService()

    struct Minion: Codable, Identifiable, Equatable {
        let id: String
        let task: String
        var status: String        // "working" | "done" | "failed"
        var detail: String?
        var startedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, task, status, detail
            case startedAt = "started_at"
        }
    }

    @Published private(set) var active: [Minion] = []

    private let activeDir: URL
    private var pollTask: Task<Void, Never>?

    private init() {
        let minionsDir = BobHome.shared.root.appendingPathComponent("minions", isDirectory: true)
        self.activeDir = minionsDir.appendingPathComponent("active", isDirectory: true)
        try? FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: minionsDir.appendingPathComponent("done", isDirectory: true),
            withIntermediateDirectories: true
        )
        reload()
        startPolling()
    }

    deinit { pollTask?.cancel() }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8s
                self?.reload()
            }
        }
    }

    private func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Minion] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let minion = try? decoder.decode(Minion.self, from: data) else { continue }
            loaded.append(minion)
        }
        let sorted = loaded.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        if sorted != active {
            active = sorted
        }
    }
}
