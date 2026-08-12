import Foundation

/// Feeds one floating panel. Each panel tails its own file with its own byte
/// offset — unrelated minion churn on MinionService's 600ms tick never touches
/// it — and every file read runs detached from the main actor. For minions it
/// follows the archive: when the events file moves to `done/` the tailer just
/// switches paths (offsets stay valid — the file moves wholesale), so a pinned
/// panel keeps its feed right when you want to read the result.
@MainActor
final class SessionFeedModel: ObservableObject {

    @Published private(set) var events: [FeedEvent] = []
    @Published private(set) var final: FeedFinal?
    @Published private(set) var minion: MinionService.Minion?
    @Published private(set) var title: String?
    @Published private(set) var cwd: String?
    @Published private(set) var gitBranch: String?
    @Published private(set) var model: String?
    @Published private(set) var lastActivity: Date?

    let source: PanelSource

    private var tailer: TranscriptTailer
    private let flavor: TranscriptParser.Flavor
    private var pollTask: Task<Void, Never>?

    init(source: PanelSource) {
        self.source = source
        switch source {
        case .minion(let m):
            minion = m
            title = m.task
            cwd = m.workdir
            flavor = .minionStream
            tailer = TranscriptTailer(url: Self.minionEventsURL(m.id, done: false))
            if let prompt = m.prompt, !prompt.isEmpty {
                // stream-json never repeats the prompt — seed the feed with it
                events = [FeedEvent(kind: .prompt, symbol: "person.fill", text: String(prompt.prefix(300)))]
            }
        case .external(let s):
            title = s.title
            cwd = s.cwd
            gitBranch = s.gitBranch
            lastActivity = s.lastActivity
            flavor = .cliTranscript
            tailer = TranscriptTailer(url: s.fileURL)
        }
    }

    deinit { pollTask?.cancel() }

    var isMinion: Bool {
        if case .minion = source { return true }
        return false
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick() async {
        let t = tailer
        let flavor = flavor
        let minionID: String? = {
            if case .minion(let m) = source { return m.id }
            return nil
        }()
        let out = await Task.detached(priority: .utility) {
            Self.poll(tailer: t, flavor: flavor, minionID: minionID)
        }.value

        tailer = out.tailer
        if !out.update.events.isEmpty {
            events.append(contentsOf: out.update.events)
            if events.count > 400 { events.removeFirst(events.count - 400) }
        }
        if let f = out.update.final { final = f }
        if let rec = out.record {
            minion = rec
            title = rec.task
            if let w = rec.workdir { cwd = w }
        }
        if let t = out.update.title { title = t }
        if cwd == nil, let c = out.update.cwd { cwd = c }
        if let b = out.update.gitBranch { gitBranch = b }
        if let m = out.update.model { model = m }
        switch flavor {
        case .cliTranscript:
            // mtime moves when claude rewrites an idle transcript's metadata —
            // the green dot would flash on a session that said nothing. Only a
            // real event advances the clock; silence leaves it where it was.
            if let at = out.update.lastEventAt, at > (lastActivity ?? .distantPast) { lastActivity = at }
        case .minionStream:
            if let mt = out.mtime { lastActivity = mt }
        }
    }

    // MARK: off-main file work

    private struct Outcome: Sendable {
        var tailer: TranscriptTailer
        var update: TranscriptParser.Update
        var record: MinionService.Minion?
        var mtime: Date?
    }

    private nonisolated static func poll(tailer: TranscriptTailer, flavor: TranscriptParser.Flavor, minionID: String?) -> Outcome {
        let fm = FileManager.default
        var t = tailer
        if let id = minionID, !fm.fileExists(atPath: t.url.path) {
            let done = minionEventsURL(id, done: true)
            if fm.fileExists(atPath: done.path) { t.url = done }
        }
        let lines = t.readNewLines()
        let update = TranscriptParser.parse(lines: lines, flavor: flavor)
        let record = minionID.flatMap(readRecord)
        let mtime = (try? fm.attributesOfItem(atPath: t.url.path))?[.modificationDate] as? Date
        return Outcome(tailer: t, update: update, record: record, mtime: mtime)
    }

    private nonisolated static func readRecord(id: String) -> MinionService.Minion? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for done in [false, true] {
            let url = minionRecordURL(id, done: done)
            if let data = try? Data(contentsOf: url),
               let m = try? decoder.decode(MinionService.Minion.self, from: data) {
                return m
            }
        }
        return nil
    }

    private nonisolated static var minionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob/minions", isDirectory: true)
    }

    private nonisolated static func minionEventsURL(_ id: String, done: Bool) -> URL {
        done ? minionsDir.appendingPathComponent("done/\(id).events.jsonl")
             : minionsDir.appendingPathComponent("\(id).events.jsonl")
    }

    private nonisolated static func minionRecordURL(_ id: String, done: Bool) -> URL {
        minionsDir.appendingPathComponent(done ? "done/\(id).json" : "active/\(id).json")
    }
}
