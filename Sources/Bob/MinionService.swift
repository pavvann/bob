import Foundation

/// Bob's minions — little agents bob delegates tasks to, running truly in
/// parallel and **surviving bob restarts**. Bob writes a `queued` record to
/// `~/bob/minions/active/`; this service launches a detached python wrapper
/// (`~/bob/bin/run-minion.py`) that flips the record to `working`, runs a real
/// background `claude` agent in the task's workdir, and writes the `done`/
/// `failed` status itself when finished. Because the wrapper owns its own
/// bookkeeping, a minion completes correctly even if bob quits mid-task — the
/// next bob launch just sees the finished record and shows it.
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

    @Published private(set) var active: [Minion] = []

    private let minionsDir: URL
    private let activeDir: URL
    private let doneDir: URL
    private let wrapperURL: URL
    private var pollTask: Task<Void, Never>?
    private var spawned: Set<String> = []

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
        // Always refresh the wrapper so script updates take effect — it's
        // app-owned infrastructure, not user content.
        try? Self.wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)

        reload()
        startPolling()
    }

    deinit { pollTask?.cancel() }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 700_000_000) // 0.7s
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

            // Pick up anything bob queued that we haven't launched yet.
            // (status "working" is left alone — its wrapper already owns it,
            // even across a bob restart.)
            if m.status == "queued", !spawned.contains(m.id) {
                spawn(m)
            }

            // Show finished cards briefly, then archive to done/.
            if m.status == "done" || m.status == "failed" {
                let age = m.finishedAt.map { Date().timeIntervalSince($0) } ?? 999
                if age > 9 {
                    archive(m)
                    continue
                }
            }
            loaded.append(m)
        }

        let sorted = loaded.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        if sorted != active { active = sorted }
    }

    /// Launch the detached wrapper. We don't wait or install a termination
    /// handler — the wrapper writes its own done/failed status, so the minion
    /// survives even if bob quits.
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

    private func archive(_ m: Minion) {
        let fm = FileManager.default
        write(m, inDone: true)
        try? fm.removeItem(at: recordURL(m.id, inDone: false))
        let logActive = minionsDir.appendingPathComponent("\(m.id).output.log")
        let logDone = doneDir.appendingPathComponent("\(m.id).output.log")
        try? fm.removeItem(at: logDone)
        try? fm.moveItem(at: logActive, to: logDone)
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
    /// Flips the record to working, runs claude in the workdir, then writes the
    /// done/failed status itself — so it completes even if bob is gone.
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
    log_path = os.path.join(minions_dir, minion_id + ".output.log")

    env = dict(os.environ)
    for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
              "CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR"]:
        env.pop(k, None)

    rc = 1
    try:
        with open(log_path, "w") as logf:
            rc = subprocess.call(
                [claude_path, "-p", "--permission-mode", "auto", prompt],
                cwd=workdir, stdout=logf, stderr=subprocess.STDOUT, env=env,
            )
    except Exception as e:
        try:
            with open(log_path, "a") as logf:
                logf.write("\n[minion wrapper error: %s]\n" % e)
        except Exception:
            pass

    summary = "done" if rc == 0 else "failed"
    try:
        with open(log_path) as f:
            lines = [l.strip() for l in f if l.strip()]
        if lines:
            summary = lines[-1][:90]
    except Exception:
        pass

    try:
        d = load()
    except Exception:
        d = {"id": minion_id, "task": "minion", "status": ""}
    d["status"] = "done" if rc == 0 else "failed"
    d["detail"] = summary
    d["finished_at"] = now_iso()
    save(d)
    """#
}
