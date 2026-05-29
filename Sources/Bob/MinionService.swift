import Foundation

/// Bob's minions — little agents bob delegates tasks to, running truly in
/// parallel, **surviving bob restarts**, and now **visible**: each minion
/// streams its actual work (tool calls, thoughts) into its card so you watch
/// the hands move. Bob writes a `queued` record to `~/bob/minions/active/`;
/// a detached python wrapper flips it to `working`, runs a real background
/// claude agent emitting stream-json into `<id>.events.jsonl`, and writes its
/// own `done`/`failed` status when finished. The Swift layer tails the events
/// file and renders a live activity feed.
@MainActor
final class MinionService: ObservableObject {
    static let shared = MinionService()

    struct Minion: Codable, Identifiable, Equatable {
        let id: String
        let task: String
        var prompt: String?
        var workdir: String?
        var status: String        // queued | working | done | failed
        var detail: String?
        var startedAt: Date?
        var finishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, task, prompt, workdir, status, detail
            case startedAt = "started_at"
            case finishedAt = "finished_at"
        }
    }

    /// A single moment in a minion's work, parsed from its stream-json events.
    struct Event: Identifiable, Equatable {
        let id = UUID()
        let symbol: String   // SF Symbol
        let text: String     // humanized one-liner
        let isThought: Bool
    }

    @Published private(set) var active: [Minion] = []
    @Published private(set) var eventsByID: [String: [Event]] = [:]

    /// Posted once when a minion transitions to done/failed, so bob can debrief
    /// you in his own voice. userInfo: task, detail, ok (Bool).
    static let minionFinished = Notification.Name("bob.minionFinished")
    private var debriefed: Set<String> = []

    private let minionsDir: URL
    private let activeDir: URL
    private let doneDir: URL
    private let wrapperURL: URL
    private var pollTask: Task<Void, Never>?
    private var spawned: Set<String> = []
    private var eventOffsets: [String: UInt64] = [:]

    private init() {
        minionsDir = BobHome.shared.root.appendingPathComponent("minions", isDirectory: true)
        activeDir = minionsDir.appendingPathComponent("active", isDirectory: true)
        doneDir = minionsDir.appendingPathComponent("done", isDirectory: true)
        let binDir = BobHome.shared.root.appendingPathComponent("bin", isDirectory: true)
        wrapperURL = binDir.appendingPathComponent("run-minion.py")

        let fm = FileManager.default
        for dir in [activeDir, doneDir, binDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? Self.wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

        reload()
        startPolling()
    }

    deinit { pollTask?.cancel() }

    func events(for id: String) -> [Event] { eventsByID[id] ?? [] }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 600_000_000)
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
                  let m = try? decoder.decode(Minion.self, from: data) else { continue }

            if m.status == "queued", !spawned.contains(m.id) {
                // the wrapper creates <id>.events.jsonl as its first act, so if
                // one already exists this minion was already started (e.g.
                // before a bob restart) — don't double-launch it.
                let evURL = minionsDir.appendingPathComponent("\(m.id).events.jsonl")
                if FileManager.default.fileExists(atPath: evURL.path) {
                    spawned.insert(m.id)
                } else {
                    spawn(m)
                }
            }

            // tail the live event stream for anything in flight
            if m.status == "working" || m.status == "queued" {
                tailEvents(id: m.id)
            }

            if m.status == "done" || m.status == "failed" {
                tailEvents(id: m.id) // catch the final events
                // fire the debrief exactly once, and only if it JUST finished —
                // a done record left in active/ from before bob launched
                // shouldn't trigger a stale "i finished X" out of nowhere.
                if !debriefed.contains(m.id) {
                    debriefed.insert(m.id)
                    let fresh = m.finishedAt.map { Date().timeIntervalSince($0) < 25 } ?? false
                    if fresh {
                        NotificationCenter.default.post(
                            name: Self.minionFinished,
                            object: nil,
                            userInfo: [
                                "task": m.task,
                                "detail": m.detail ?? "",
                                "ok": m.status == "done",
                            ]
                        )
                    }
                }
                let age = m.finishedAt.map { Date().timeIntervalSince($0) } ?? 999
                if age > 10 {
                    archive(m)
                    continue
                }
            }
            loaded.append(m)
        }

        let sorted = loaded.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        if sorted != active { active = sorted }
    }

    private func spawn(_ minion: Minion) {
        spawned.insert(minion.id)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pythonPath)
        process.arguments = [
            wrapperURL.path,
            recordURL(minion.id, inDone: false).path,
            ClaudeBridge.claudePath,
        ]
        do {
            try process.run()
        } catch {
            var m = minion
            m.status = "failed"
            m.detail = "couldn't launch minion wrapper"
            m.startedAt = m.startedAt ?? Date()
            m.finishedAt = Date()
            write(m)
        }
    }

    // MARK: live event tailing

    private func tailEvents(id: String) {
        let url = minionsDir.appendingPathComponent("\(id).events.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let firstRead = (eventOffsets[id] == nil)
        var offset = eventOffsets[id] ?? 0
        if firstRead {
            // only the last ~40 events ever render — on the first read (which
            // after a restart may sit over a multi-MB file) start from a bounded
            // tail rather than re-reading the whole thing on the main loop.
            let end = (try? handle.seekToEnd()) ?? 0
            offset = end > 65_536 ? end - 65_536 : 0
        }
        do {
            try handle.seek(toOffset: offset)
        } catch { return }
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        // Only consume through the LAST complete line — a JSON object whose line
        // hasn't finished writing yet would fail to parse and be lost forever if
        // we advanced past it. Leave the partial tail for the next poll.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let throughLast = data[...lastNewline]
        eventOffsets[id] = offset + UInt64(throughLast.count)

        // If we jumped into the middle of the file, the first line is a partial
        // fragment — drop it.
        var consumable = throughLast
        if firstRead, offset > 0, let firstNewline = consumable.firstIndex(of: 0x0A) {
            consumable = consumable[consumable.index(after: firstNewline)...]
        }
        guard let text = String(data: Data(consumable), encoding: .utf8) else { return }
        var appended: [Event] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            appended.append(contentsOf: Self.parseEvents(from: obj))
        }
        guard !appended.isEmpty else { return }
        var list = eventsByID[id] ?? []
        list.append(contentsOf: appended)
        if list.count > 40 { list.removeFirst(list.count - 40) }
        eventsByID[id] = list
    }

    /// Turn one stream-json object into zero or more humanized activity events.
    private nonisolated static func parseEvents(from obj: [String: Any]) -> [Event] {
        guard let type = obj["type"] as? String else { return [] }
        guard type == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        var out: [Event] = []
        for block in content {
            guard let btype = block["type"] as? String else { continue }
            if btype == "text", let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                let firstLine = t.split(separator: "\n").first.map(String.init) ?? t
                out.append(Event(symbol: "bubble.left", text: String(firstLine.prefix(80)), isThought: true))
            } else if btype == "tool_use", let name = block["name"] as? String {
                let input = block["input"] as? [String: Any] ?? [:]
                out.append(humanizeTool(name: name, input: input))
            }
        }
        return out
    }

    private nonisolated static func humanizeTool(name: String, input: [String: Any]) -> Event {
        func base(_ key: String) -> String {
            guard let p = input[key] as? String else { return "" }
            return (p as NSString).lastPathComponent
        }
        switch name {
        case "Read":
            return Event(symbol: "doc.text", text: "reading \(base("file_path"))", isThought: false)
        case "Edit", "Write", "NotebookEdit":
            return Event(symbol: "pencil", text: "editing \(base("file_path"))", isThought: false)
        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            return Event(symbol: "terminal", text: "running \(String(cmd.prefix(46)))", isThought: false)
        case "Grep":
            return Event(symbol: "magnifyingglass", text: "searching \((input["pattern"] as? String) ?? "")", isThought: false)
        case "Glob":
            return Event(symbol: "folder", text: "globbing \((input["pattern"] as? String) ?? "")", isThought: false)
        case "WebSearch":
            return Event(symbol: "globe", text: "searching web: \((input["query"] as? String) ?? "")", isThought: false)
        case "WebFetch":
            let u = (input["url"] as? String) ?? ""
            return Event(symbol: "globe", text: "fetching \(URL(string: u)?.host ?? u)", isThought: false)
        case "Task":
            return Event(symbol: "person.2", text: "spawning a sub-agent", isThought: false)
        case "Skill":
            return Event(symbol: "wand.and.stars", text: "using \((input["command"] as? String) ?? "a skill")", isThought: false)
        default:
            return Event(symbol: "gearshape", text: name.lowercased(), isThought: false)
        }
    }

    // MARK: archive

    private func archive(_ m: Minion) {
        let fm = FileManager.default
        write(m, inDone: true)
        try? fm.removeItem(at: recordURL(m.id, inDone: false))
        let evActive = minionsDir.appendingPathComponent("\(m.id).events.jsonl")
        let evDone = doneDir.appendingPathComponent("\(m.id).events.jsonl")
        try? fm.removeItem(at: evDone)
        try? fm.moveItem(at: evActive, to: evDone)
        eventsByID[m.id] = nil
        eventOffsets[m.id] = nil
    }

    private func recordURL(_ id: String, inDone: Bool) -> URL {
        (inDone ? doneDir : activeDir).appendingPathComponent("\(id).json")
    }

    private func write(_ m: Minion, inDone: Bool = false) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(m) {
            try? data.write(to: recordURL(m.id, inDone: inDone), options: .atomic)
        }
    }

    private static let pythonPath: String = {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/python3"
    }()

    /// Self-reporting minion runner. Args: <record-json-path> <claude-path>.
    /// Runs claude in stream-json mode, teeing events to <id>.events.jsonl, then
    /// writes its own done/failed status + a prose summary pulled from the final
    /// `result` event — so it completes even if bob is gone.
    private static let wrapperScript = #"""
    #!/usr/bin/env python3
    import json, sys, subprocess, os, datetime

    record_path = sys.argv[1]
    claude_path = sys.argv[2]

    def now_iso():
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def load():
        with open(record_path) as f:
            return json.load(f)

    def save(d):
        tmp = record_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f, indent=2, sort_keys=True)
        os.replace(tmp, record_path)

    try:
        d = load()
    except Exception:
        sys.exit(1)

    d["status"] = "working"
    d["started_at"] = now_iso()
    d["detail"] = "working"
    save(d)

    prompt = d.get("prompt") or d.get("task", "")
    workdir = d.get("workdir") or os.path.expanduser("~/bob")
    if not os.path.isdir(workdir):
        workdir = os.path.expanduser("~/bob")
    minion_id = d["id"]

    minions_dir = os.path.dirname(os.path.dirname(record_path))
    events_path = os.path.join(minions_dir, minion_id + ".events.jsonl")

    env = dict(os.environ)
    for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
              "CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR"]:
        env.pop(k, None)

    summary = None
    is_error = True
    rc = 1
    try:
        with open(events_path, "w") as evf:
            proc = subprocess.Popen(
                [claude_path, "-p", "--output-format", "stream-json", "--verbose",
                 "--permission-mode", "auto", prompt],
                cwd=workdir, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env=env, text=True, bufsize=1,
            )
            for line in proc.stdout:
                evf.write(line)
                evf.flush()
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") == "result":
                    summary = obj.get("result")
                    is_error = bool(obj.get("is_error"))
            rc = proc.wait()
    except Exception as e:
        try:
            with open(events_path, "a") as evf:
                evf.write(json.dumps({"type": "wrapper_error", "error": str(e)}) + "\n")
        except Exception:
            pass

    ok = (rc == 0) and not is_error
    if not summary:
        summary = "done" if ok else "failed"
    summary = " ".join(summary.split())[:120]

    try:
        d = load()
    except Exception:
        d = {"id": minion_id, "task": "minion", "status": ""}
    d["status"] = "done" if ok else "failed"
    d["detail"] = summary
    d["finished_at"] = now_iso()
    save(d)
    """#
}
