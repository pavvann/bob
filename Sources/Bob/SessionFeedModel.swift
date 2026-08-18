import Combine
import Foundation
import Observation

/// Feeds one floating panel. File-fed panels (minions, external cli sessions)
/// tail their own file with their own byte offset — unrelated minion churn on
/// MinionService's 600ms tick never touches them — and every file read runs
/// detached from the main actor. For minions it follows the archive: when the
/// events file moves to `done/` the tailer just switches paths (offsets stay
/// valid — the file moves wholesale), so a pinned panel keeps its feed right
/// when you want to read the result. A `.live` panel has no file at all: it
/// reads one of bob's own ClaudeSessions straight from the object.
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
    /// The in-flight tool line ("reading Foo.swift") — live panels only.
    @Published private(set) var activity: String?
    /// What the dot says for a live in-app session; nil for file-fed panels.
    @Published private(set) var liveStatus: SessionStatus?
    /// A live session with no process behind it yet — the panel offers to wake
    /// it instead of sitting there looking broken.
    @Published private(set) var isCold = false

    let source: PanelSource

    private var tailer: TranscriptTailer?
    private let flavor: TranscriptParser.Flavor
    private var pollTask: Task<Void, Never>?
    private var liveTap: AnyCancellable?
    /// Invalidates a stale transcript watch after stop() — the re-arming
    /// observation below checks it before every re-ingest.
    private var liveGeneration = 0
    /// entry id → the row it produced. A streaming turn re-ingests per
    /// coalesced flush; rows whose text hasn't moved hand back the very same
    /// FeedEvent, identity included, so SwiftUI redraws the one row that's
    /// growing and not the whole feed.
    private var liveRows: [UUID: FeedEvent] = [:]

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
        case .live(let s):
            title = s.config.name
            cwd = s.config.cwd.path
            model = s.config.model
            flavor = .minionStream      // unused: nothing on disk to parse
            tailer = nil
        }
        if case .live(let s) = source { ingestLive(s) }
    }

    deinit { pollTask?.cancel() }

    var isMinion: Bool {
        if case .minion = source { return true }
        return false
    }

    var isLive: Bool {
        if case .live = source { return true }
        return false
    }

    func start() {
        if case .live(let session) = source {
            guard liveTap == nil else { return }
            // BACKFILL, always, before subscribing: `session.events` mints a
            // fresh multicast stream per access and replays nothing, so the
            // transcript is the only history there is. A panel opened mid-turn
            // has to read it rather than wait for what comes next.
            ingestLive(session)
            // boundaries (state, question, agents) — low-frequency since the
            // transcript moved off the session's published surface (P2b)
            liveTap = session.objectWillChange
                .receive(on: DispatchQueue.main)   // willChange fires pre-mutation
                .sink { [weak self] in
                    MainActor.assumeIsolated { self?.ingestLive(session) }
                }
            liveGeneration += 1
            watchTranscript(session, generation: liveGeneration)
            return
        }
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
        liveTap = nil
        liveGeneration += 1
    }

    /// Per-flush text comes straight from the store: one observation of its
    /// revision, re-armed after every read. willSet fires pre-mutation, so
    /// the re-read hops the actor once and lands post-change.
    private func watchTranscript(_ session: ClaudeSession, generation: Int) {
        withObservationTracking {
            _ = session.transcript.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.liveGeneration == generation else { return }
                self.ingestLive(session)
                self.watchTranscript(session, generation: generation)
            }
        }
    }

    /// The cold panel's button. Idempotent — ClaudeSession.spawn() only acts
    /// from `.unspawned`/`.failed`, so a double click can't fork a second
    /// process onto one conversation.
    func wake() {
        guard case .live(let session) = source else { return }
        session.spawn()
        ingestLive(session)
    }

    // MARK: live in-app session (PanelSource.live)

    /// Rebuild the panel's face from what the session holds. Runs once per
    /// coalesced flush, hence the row cache and the equality gates: an update
    /// that changes nothing publishes nothing.
    private func ingestLive(_ session: ClaudeSession) {
        var rows: [FeedEvent] = []
        var cache: [UUID: FeedEvent] = [:]
        // hidden entries (debrief injections) are invisible here for the same
        // reason they're invisible in chat — the owner never wrote them
        for entry in session.transcript.entries where !entry.hidden {
            guard let text = Self.tidy(entry.text, limit: entry.role == .you ? 300 : 280)
            else { continue }
            let row: FeedEvent
            if let cached = liveRows[entry.id], cached.text == text {
                row = cached
            } else {
                row = FeedEvent(kind: Self.kind(entry.role), symbol: Self.symbol(entry), text: text)
            }
            cache[entry.id] = row
            rows.append(row)
        }
        liveRows = cache            // task notices that swept themselves drop out
        if rows != events {
            events = rows
            lastActivity = Date()
        }
        let streaming = session.isStreaming
        let tool = streaming ? session.transcript.entries.last(where: { $0.activity != nil })?.activity : nil
        if tool != activity {
            activity = tool
            if tool != nil { lastActivity = Date() }
        }
        // equality-gated like everything above: this runs per coalesced flush,
        // and an unchanged publish still invalidates the whole panel
        let status = SessionManager.status(of: session)
        if status != liveStatus { liveStatus = status }
        let cold = session.state == .unspawned
        if cold != isCold { isCold = cold }
        // the closing numbers belong to a turn that's over; mid-turn they'd be
        // last turn's, pretending to be this one's
        let numbers = streaming ? nil : session.lastResult.map(Self.numbers)
        if numbers != final { final = numbers }
    }

    private static func kind(_ role: ClaudeSession.Role) -> FeedEvent.Kind {
        switch role {
        case .you: return .prompt
        case .bob: return .thought
        case .notice: return .action
        }
    }

    private static func symbol(_ entry: TranscriptEntry) -> String {
        switch entry.role {
        case .you: return "person.fill"
        case .bob: return "bubble.left"
        // task chatter is a doorbell; everything else a notice says is health
        case .notice: return entry.taskId == nil ? "exclamationmark.circle" : "bell"
        }
    }

    /// One row's worth of an entry: whitespace collapsed, so a markdown reply
    /// doesn't spend the row's two lines on blanks.
    private static func tidy(_ text: String, limit: Int) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(limit))
    }

    /// The last turn's numbers — the same footer a minion gets, minus the
    /// result text (the reply is already the row above it).
    private static func numbers(_ r: TurnResult) -> FeedFinal {
        FeedFinal(
            resultText: nil,
            durationMs: r.durationMs,
            costUSD: r.costUSD,
            numTurns: r.numTurns,
            // an interrupt reports is_error too, and it isn't one (edge 4)
            isError: r.isError && r.terminalReason != "aborted_streaming"
        )
    }

    // MARK: file-fed sources

    private func tick() async {
        guard let t = tailer else { return }
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
        // every write below is guarded: this ticks at 1Hz per open panel, and
        // re-publishing an identical value still redraws the panel
        if let rec = out.record {
            if rec != minion { minion = rec }
            if rec.task != title { title = rec.task }
            if let w = rec.workdir, w != cwd { cwd = w }
        }
        if let t = out.update.title, t != title { title = t }
        if cwd == nil, let c = out.update.cwd { cwd = c }
        if let b = out.update.gitBranch, b != gitBranch { gitBranch = b }
        if let m = out.update.model, m != model { model = m }
        switch flavor {
        case .cliTranscript:
            // mtime moves when claude rewrites an idle transcript's metadata —
            // the green dot would flash on a session that said nothing. Only a
            // real event advances the clock; silence leaves it where it was.
            if let at = out.update.lastEventAt, at > (lastActivity ?? .distantPast) { lastActivity = at }
        case .minionStream:
            if let mt = out.mtime, mt != lastActivity { lastActivity = mt }
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
