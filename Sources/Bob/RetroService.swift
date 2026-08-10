import Foundation

/// Bob's nightly retro — the pass where bob reviews its own day and improves
/// itself: promotes stale `MEMORY.md` bullets into the wiki, fixes `index.md`
/// drift, files `backlog.md` items, drafts skills for repeated pipelines, and
/// dispatches at most one small code minion.
///
/// No launchd, no second lifecycle: a 5-minute poll with **catch-up**. If bob
/// wasn't running when the day closed, the retro runs on the next launch — a
/// retro nobody was around to watch has no deadline. The mechanism is just a
/// normal minion record dropped into `minions/active/`, so the retro is a
/// visible card, survives restarts, and debriefs in bob's voice when it lands.
@MainActor
final class RetroService {
    static let shared = RetroService()

    /// A retro day closes at 04:00 local — he works past midnight, so calendar
    /// midnight is the wrong seam.
    static let dayEndHour = 4

    /// Let the tiles settle and the open line land before touching anything.
    private static let firstCheckDelay: UInt64 = 120_000_000_000   // 2 min
    private static let pollInterval: UInt64 = 300_000_000_000      // 5 min

    private let root: URL
    private let stateFile: URL
    private let activeDir: URL
    private var pollTask: Task<Void, Never>?

    private init() {
        root = BobHome.shared.root
        stateFile = root.appendingPathComponent("state/retro.json")
        activeDir = root.appendingPathComponent("minions/active", isDirectory: true)
        startPolling()
    }

    deinit { pollTask?.cancel() }

    private func startPolling() {
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.firstCheckDelay)
            while !Task.isCancelled {
                self?.checkNow()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    // MARK: the check

    /// Queues a retro for the most recent completed retro-day if one hasn't run
    /// yet and nothing retro-shaped is already in flight. Idempotent, cheap.
    func checkNow() {
        let day = Self.lastCompletedDay()
        guard lastRun() < day else { return }
        guard !retroInFlight() else { return }

        // write-before-queue: a retro that dies mid-flight skips its day rather
        // than ever running twice. the failure is visible on the minion card.
        recordLastRun(day)
        queueRetro(for: day)
    }

    /// The most recent **completed** retro-day, as `yyyy-MM-dd`.
    ///
    /// Retro-day D covers D 00:00 → D+1 04:00, so it only becomes reviewable at
    /// 04:00 the next morning: at 03:59 on the 11th the last completed day is
    /// still the 9th; at 04:01 it flips to the 10th.
    static func lastCompletedDay(now: Date = Date(), calendar: Calendar = .current) -> String {
        // wall-clock arithmetic, not `now - 28h`: subtracting hours across a DST
        // seam slides the boundary by an hour, and "before 4am" is a wall-clock
        // idea. before 04:00 we're still inside yesterday's retro-day, so the
        // last closed one is the day before that.
        let hour = calendar.component(.hour, from: now)
        let back = hour < dayEndHour ? -2 : -1
        let midnight = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: back, to: midnight) ?? midnight
        return dateString(day, calendar: calendar)
    }

    static func dateString(_ date: Date, calendar: Calendar = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    // MARK: state/retro.json

    /// Day last reviewed, or `""` when the file is missing/unreadable (which
    /// makes the first launch run one catch-up retro — by design).
    private func lastRun() -> String {
        guard let data = try? Data(contentsOf: stateFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let day = obj["last_run"] as? String
        else { return "" }
        return day
    }

    private func recordLastRun(_ day: String) {
        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = "{\n  \"last_run\": \"\(day)\"\n}\n"
        try? Data(json.utf8).write(to: stateFile, options: .atomic)
    }

    // MARK: the minion record

    private func retroInFlight() -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: activeDir, includingPropertiesForKeys: nil)) ?? []
        // records are `<id>.json` and every retro id carries `-retro-`
        return files.contains { $0.lastPathComponent.contains("-retro-") }
    }

    private func queueRetro(for day: String) {
        let id = "\(Int(Date().timeIntervalSince1970))-retro-\(day)"
        let record: [String: Any] = [
            "id": id,
            "task": "nightly retro \(day)",
            "prompt": Self.prompt(for: day, root: root),
            "workdir": root.path,
            "lens": "retro",
            "origin": "retro",
            "status": "queued",
        ]
        try? FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: activeDir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    /// The retro prompt. Deliberately thin — the judgment lives in
    /// `~/bob/wiki/bob/retro.md` so bob can refine its own protocol; this
    /// template only supplies the date and points at the sources.
    static func prompt(for day: String, root: URL) -> String {
        // claude's own transcript store encodes a project dir by swapping `/` for `-`
        let encoded = root.path.replacingOccurrences(of: "/", with: "-")
        let transcripts = "~/.claude/projects/\(encoded)/*.jsonl"
        return """
        nightly retro for \(day). you are bob reviewing your own day. follow \
        ~/bob/wiki/bob/retro.md as protocol; the lens has given you MEMORY.md, index.md
        and backlog.md already.

        sources for the day:
        - transcripts: \(transcripts) modified on \(day)
          (read user + assistant text lines; skip tool results — they're huge)
        - finished minions: ~/bob/minions/done/*.json from \(day)

        do, in order:
        1. MEMORY.md: any bullet older than ~14 days or grown past its topic → promote to
           a wiki page, add the index row, mark the bullet `→ moved to ...`. never delete.
        2. index.md drift: pages that exist but aren't listed, summaries that lie, dead rows.
        3. backlog.md: append papercuts / drift / ideas actually observed today (schema in
           the file header). dedupe against existing items.
        4. skills: if today's transcripts show the same multi-step pipeline ≥3 times
           (across sessions), draft skills/<name>.md — mechanical parts as a
           skills/bin/<name> script, thin prose wrapper, per the play-music pattern. also
           write the ~/bob/.claude/skills/<name>/SKILL.md adapter (frontmatter with
           description + trigger phrases, body: "follow ~/bob/skills/<name>.md").
        5. dispatch: at most ONE `S` backlog item — write a minion record with
           lens "bob-dev", origin "self", workdir /Users/pawan/Code/bob. skip if any
           bob/* item is already in flight.
        6. append to log.md: `## [\(day)] retro | <one-line summary of what changed>`.

        hard rules: everything additive; never rewrite history; if a source is missing,
        note it in log.md and move on. finish with a 2-line summary (it becomes your
        debrief to pawan).
        """
    }
}
