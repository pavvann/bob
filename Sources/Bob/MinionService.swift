import Foundation

/// Bob's minions — little agents bob delegates tasks to, running truly in
/// parallel, **surviving bob restarts**, and now **visible**: each minion
/// streams its actual work (tool calls, thoughts) into its card so you watch
/// the hands move. Bob writes a `queued` record to `~/bob/minions/active/`;
/// a detached python wrapper flips it to `working`, runs a real background
/// claude agent emitting stream-json into `<id>.events.jsonl`, and writes its
/// own `done`/`failed` status when finished. The Swift layer tails the events
/// file and renders a live activity feed.
///
/// The queue is application-critical and has no visible surface of its own: a
/// minion must be spawned, archived and debriefed whether or not anyone is
/// looking at a card. So the whole disk pass lives in a `Reader` actor driven by
/// the directory watcher, with one slow safety sweep behind it, and the main
/// actor only ever applies the result.
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
        /// Optional lens spec (`bob-dev`, `project:webapp`) — resolved by the
        /// swift layer at spawn time and appended to the minion's system prompt.
        var lens: String?
        /// Who queued this: "user" (default) | "retro" | "self". Carried so a
        /// debrief can say whose minion just finished.
        var origin: String?
        /// Optional model override (`sonnet`, `haiku`, or a full id) — passed
        /// through to `claude --model` by the wrapper. Absent → the
        /// user-settings default.
        var model: String?
        var startedAt: Date?
        var finishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, task, prompt, workdir, status, detail, lens, origin, model
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

    private let reader: Reader
    private var sweepTask: Task<Void, Never>?

    /// The floor on watcher-driven passes — a working minion appends to its
    /// events file constantly, and this was the old poll's period anyway.
    private static let floor: TimeInterval = 0.6
    /// The safety net: nothing here needs a clock to be correct, but a minion
    /// whose record never lands (or an archival that missed its window) must not
    /// wait for the next filesystem event to be noticed.
    private static let sweepInterval: UInt64 = 30_000_000_000

    private init() {
        let minionsDir = BobHome.shared.root.appendingPathComponent("minions", isDirectory: true)
        let activeDir = minionsDir.appendingPathComponent("active", isDirectory: true)
        let doneDir = minionsDir.appendingPathComponent("done", isDirectory: true)
        let binDir = BobHome.shared.root.appendingPathComponent("bin", isDirectory: true)
        let wrapperURL = binDir.appendingPathComponent("run-minion.py")

        let fm = FileManager.default
        for dir in [activeDir, doneDir, binDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? Self.wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

        reader = Reader(minionsDir: minionsDir, activeDir: activeDir,
                        doneDir: doneDir, wrapperURL: wrapperURL)

        DirWatcher.shared.acquire(path: minionsDir.path, id: "minions", floor: Self.floor) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: Self.sweepInterval)
            }
        }
    }

    deinit { sweepTask?.cancel() }

    func events(for id: String) -> [Event] { eventsByID[id] ?? [] }

    private func refresh() {
        Task { [weak self] in
            guard let self else { return }
            self.apply(await self.reader.sweep())
        }
    }

    /// Publishes are `==`-guarded and per-key: one minion's events must not
    /// invalidate every other card.
    private func apply(_ batch: Reader.Batch) {
        if batch.active != active { active = batch.active }
        for (id, events) in batch.appended {
            var list = eventsByID[id] ?? []
            list.append(contentsOf: events)
            if list.count > 40 { list.removeFirst(list.count - 40) }
            eventsByID[id] = list
        }
        // after the appends: the final events of a minion that archived in this
        // same pass go with it.
        for id in batch.archived where eventsByID[id] != nil { eventsByID[id] = nil }
        for done in batch.debriefs {
            NotificationCenter.default.post(
                name: Self.minionFinished,
                object: nil,
                userInfo: ["task": done.task, "detail": done.detail, "ok": done.ok]
            )
        }
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

    // MARK: - the disk pass

    /// Everything that touches the minions directory. An actor rather than a
    /// detached function because the pass carries state across runs — which
    /// minions have been launched, which have been debriefed, how far into each
    /// events file we've read — and that state must be serialized without ever
    /// visiting the main thread.
    private actor Reader {
        struct Debrief: Sendable {
            let task: String
            let detail: String
            let ok: Bool
        }

        struct Batch: Sendable {
            var active: [Minion] = []
            var appended: [String: [Event]] = [:]
            var archived: [String] = []
            var debriefs: [Debrief] = []
        }

        private let minionsDir: URL
        private let activeDir: URL
        private let doneDir: URL
        private let wrapperURL: URL

        private var spawned: Set<String> = []
        private var debriefed: Set<String> = []
        private var eventOffsets: [String: UInt64] = [:]

        init(minionsDir: URL, activeDir: URL, doneDir: URL, wrapperURL: URL) {
            self.minionsDir = minionsDir
            self.activeDir = activeDir
            self.doneDir = doneDir
            self.wrapperURL = wrapperURL
        }

        func sweep() -> Batch {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil)) ?? []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var batch = Batch()
            var loaded: [Minion] = []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let m = try? decoder.decode(Minion.self, from: data) else { continue }

                if m.status == "queued", !spawned.contains(m.id) {
                    // the wrapper creates <id>.events.jsonl as its first act, so if
                    // one already exists this minion was already started (e.g.
                    // before a bob restart) — don't double-launch it.
                    let evURL = minionsDir.appendingPathComponent("\(m.id).events.jsonl")
                    if fm.fileExists(atPath: evURL.path) {
                        spawned.insert(m.id)
                    } else {
                        spawn(m)
                    }
                }

                // tail the live event stream for anything in flight
                if m.status == "working" || m.status == "queued" {
                    batch.appended[m.id] = tailEvents(id: m.id)
                }

                if m.status == "done" || m.status == "failed" {
                    batch.appended[m.id] = tailEvents(id: m.id) // catch the final events
                    // fire the debrief exactly once, and only if it JUST finished —
                    // a done record left in active/ from before bob launched
                    // shouldn't trigger a stale "i finished X" out of nowhere.
                    if !debriefed.contains(m.id) {
                        debriefed.insert(m.id)
                        let fresh = m.finishedAt.map { Date().timeIntervalSince($0) < 25 } ?? false
                        if fresh {
                            batch.debriefs.append(Debrief(task: m.task,
                                                          detail: m.detail ?? "",
                                                          ok: m.status == "done"))
                        }
                    }
                    let age = m.finishedAt.map { Date().timeIntervalSince($0) } ?? 999
                    if age > 10 {
                        archive(m)
                        batch.archived.append(m.id)
                        continue
                    }
                }
                loaded.append(m)
            }
            batch.appended = batch.appended.filter { !$0.value.isEmpty }
            batch.active = loaded.sorted {
                ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast)
            }
            return batch
        }

        private func spawn(_ minion: Minion) {
            spawned.insert(minion.id)
            var args = [
                wrapperURL.path,
                recordURL(minion.id, inDone: false).path,
                ClaudeBridge.claudePath,
            ]
            if let lensPath = prepareLens(for: minion) { args.append(lensPath) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MinionService.pythonPath)
            process.arguments = args
            // the wrapper's `env = dict(os.environ)` inherits whatever we give it
            // here, so fixing PATH on this process fixes it for the claude child
            // the wrapper spawns too — no need to touch the wrapper script itself.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ClaudeBridge.spawnPATH
            process.environment = env
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

        /// Assemble the minion's lens (if it carries one) into `<id>.lens.txt` and
        /// hand back that path for the wrapper's argv[3]. Never fails a minion: a
        /// missing or broken lens just means it runs with today's plain system
        /// prompt — LensStore has already logged why to `state/lens-debug.log`.
        private func prepareLens(for minion: Minion) -> String? {
            let url = lensURL(minion.id)
            guard let spec = minion.lens?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !spec.isEmpty,
                  let ctx = LensStore.shared.resolve(spec),
                  (try? ctx.text.write(to: url, atomically: true, encoding: .utf8)) != nil
            else {
                // never leave a stale block from an earlier attempt lying around
                // where the wrapper could pick it up.
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return url.path
        }

        private func lensURL(_ id: String) -> URL {
            minionsDir.appendingPathComponent("\(id).lens.txt")
        }

        // MARK: live event tailing

        private func tailEvents(id: String) -> [Event] {
            let url = minionsDir.appendingPathComponent("\(id).events.jsonl")
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }

            let firstRead = (eventOffsets[id] == nil)
            var offset = eventOffsets[id] ?? 0
            if firstRead {
                // only the last ~40 events ever render — on the first read (which
                // after a restart may sit over a multi-MB file) start from a bounded
                // tail rather than re-reading the whole thing.
                let end = (try? handle.seekToEnd()) ?? 0
                offset = end > 65_536 ? end - 65_536 : 0
            }
            do {
                try handle.seek(toOffset: offset)
            } catch { return [] }
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return [] }

            // Only consume through the LAST complete line — a JSON object whose line
            // hasn't finished writing yet would fail to parse and be lost forever if
            // we advanced past it. Leave the partial tail for the next pass.
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
            let throughLast = data[...lastNewline]
            eventOffsets[id] = offset + UInt64(throughLast.count)

            // If we jumped into the middle of the file, the first line is a partial
            // fragment — drop it.
            var consumable = throughLast
            if firstRead, offset > 0, let firstNewline = consumable.firstIndex(of: 0x0A) {
                consumable = consumable[consumable.index(after: firstNewline)...]
            }
            guard let text = String(data: Data(consumable), encoding: .utf8) else { return [] }
            var appended: [Event] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                else { continue }
                appended.append(contentsOf: MinionService.parseEvents(from: obj))
            }
            return appended
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
            try? fm.removeItem(at: lensURL(m.id))   // the assembled block was scratch
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
    }

    private nonisolated static let pythonPath: String = {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/python3"
    }()

    /// Self-reporting minion runner.
    /// Args: <record-json-path> <claude-path> [<lens-file-path>].
    /// Runs claude in stream-json mode, teeing events to <id>.events.jsonl, then
    /// writes its own done/failed status + a prose summary pulled from the final
    /// `result` event — so it completes even if bob is gone.
    private static let wrapperScript = #"""
    #!/usr/bin/env python3
    import json, sys, subprocess, os, datetime

    record_path = sys.argv[1]
    claude_path = sys.argv[2]
    lens_path = sys.argv[3] if len(sys.argv) > 3 else None

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

    argv = [claude_path, "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "auto"]
    if lens_path and os.path.exists(lens_path):
        argv += ["--append-system-prompt-file", lens_path]
    # workers default to sonnet — never the CLI default, which follows the
    # newest (priciest) tier and once burned a monthly spend cap (2026-08-13)
    model = d.get("model") or "sonnet"
    if model:
        argv += ["--model", model]
    argv.append(prompt)

    summary = None
    is_error = True
    rc = 1
    try:
        with open(events_path, "w") as evf:
            proc = subprocess.Popen(
                argv,
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
