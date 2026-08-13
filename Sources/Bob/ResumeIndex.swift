import Foundation

/// What `/resume` needs to know: which conversations a project already has on
/// disk, what each one was about, and how to read one back into a transcript.
///
/// The CLI keeps every conversation as jsonl under `~/.claude/projects/<cwd
/// with slashes turned to dashes>/<conversation id>.jsonl`, and `--resume
/// <id>` picks one up. That layout is the CLI's, not ours, so nothing here
/// trusts it blindly: a missing directory falls back to asking the
/// transcripts themselves which one belongs to this cwd, and every parse
/// branch treats a malformed line as noise to skip rather than a reason to
/// fail. Everything is pure and off-actor — the store calls it from a
/// background task and hands finished values to the main actor.
enum ResumeIndex {

    /// One resumable conversation, reduced to what a picker row shows.
    struct Conversation: Identifiable, Equatable, Sendable {
        /// The id the CLI knows this conversation by: the file's stem, and what
        /// `--resume` takes.
        let id: UUID
        let fileURL: URL
        /// The CLI's own summary when it wrote one, else the first thing said.
        let title: String
        let lastActivity: Date
        /// Prompts, not messages — the unit a person counts a conversation in.
        /// A coding session's transcript is mostly tool traffic; counting that
        /// would say "1,400 messages" about an afternoon of eight questions.
        let prompts: Int
        /// Somebody typed into a terminal here. The CLI stamps those prompts
        /// `origin: human` / `promptSource: typed`; everything an SDK client
        /// sends — bob's own stdin, a Task subagent, a doc-generation run —
        /// says `sdk` instead.
        let humanTyped: Bool
        let gitBranch: String?
        /// `entrypoint: sdk-cli` means bob spawned it; a terminal session says
        /// `cli`. Both are resumable — the row says which so you can tell your
        /// own chat from a Ghostty session in the same project.
        let fromBob: Bool

        /// Nothing to come back to. A conversation someone typed always counts,
        /// however short — that's the CLI's own bar for `/resume`, and matching
        /// it is why a project with twenty-five transcripts lists the one
        /// session you actually had. Everything else on disk is machinery: the
        /// greeting line, the nightly retro, every minion, every Task subagent
        /// — one prompt fired at a model, no dialogue to resume. Bob's own
        /// chats survive on the same rule, because they run several prompts
        /// deep even though the CLI files them as `sdk`.
        ///
        /// The index still reports these; deciding not to show them is the
        /// picker's call.
        var isOneShot: Bool { !humanTyped && prompts < 2 }
    }

    /// A reconstructed turn, ready to become a transcript row.
    struct Turn: Sendable {
        let fromYou: Bool
        let text: String
    }

    // MARK: - locating a project

    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// The CLI's directory for a working directory. The mangling rule is theirs
    /// (`/` → `-`), so when the guess misses we ask the transcripts instead of
    /// showing an empty picker and calling the project historyless.
    static func projectDirectory(for cwd: URL, root: URL? = nil) -> URL? {
        let root = root ?? projectsRoot
        let path = cwd.standardizedFileURL.path
        let direct = root.appendingPathComponent(path.replacingOccurrences(of: "/", with: "-"),
                                                isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDir), isDir.boolValue {
            return direct
        }
        return searchByRecordedCwd(root: root, path: path)
    }

    /// Every transcript records the cwd it ran in. Read one file per candidate
    /// directory (newest, head only) and match on that.
    private static func searchByRecordedCwd(root: URL, path: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return nil }
        for dir in dirs {
            guard let newest = transcripts(in: dir).first,
                  let head = headLines(of: newest, bytes: 64 * 1024).first(where: { $0.contains("\"cwd\"") }),
                  let obj = json(head),
                  let recorded = obj["cwd"] as? String
            else { continue }
            if URL(fileURLWithPath: recorded).standardizedFileURL.path == path { return dir }
        }
        return nil
    }

    /// Transcripts in a directory, newest first. A conversation is named by its
    /// id, so anything else in there is somebody else's file — filtered here
    /// rather than later, so a stray `notes.jsonl` can't eat a slot out of a
    /// caller's limit.
    private static func transcripts(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir,
                                               includingPropertiesForKeys: [.contentModificationDateKey],
                                               options: [.skipsHiddenFiles])) ?? []
        return urls.filter {
                       $0.pathExtension == "jsonl"
                       && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
                   }
                   .sorted { modified($0) > modified($1) }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    // MARK: - the list

    /// This project's conversations, newest first. `limit` bounds the work: a
    /// project with a hundred old threads shouldn't cost a hundred file reads
    /// to show you the handful you might actually want.
    static func conversations(for cwd: URL, root: URL? = nil, limit: Int = 40) -> [Conversation] {
        guard let dir = projectDirectory(for: cwd, root: root) else { return [] }
        return transcripts(in: dir).prefix(limit).compactMap { conversation(at: $0) }
    }

    /// One row's worth of metadata without parsing the whole file: the head
    /// carries identity, the first prompt, and enough prompts to count; the tail
    /// carries the CLI's summary if it compacted. A 40MB coding transcript costs
    /// the same as a small one.
    static func conversation(at url: URL, headBytes: Int = 256 * 1024) -> Conversation? {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }

        var branch: String?
        var fromBob = false
        var firstPrompt: String?
        var headPrompts = 0
        for line in headLines(of: url, bytes: headBytes) {
            guard let obj = json(line) else { continue }
            // "HEAD" is what the CLI records outside a repo (~/bob keeps no git
            // by design) — that's an absence, not a branch name
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            if let e = obj["entrypoint"] as? String { fromBob = (e == "sdk-cli") }
            if (obj["type"] as? String) == "user",
               (obj["isSidechain"] as? Bool) != true,
               (obj["isMeta"] as? Bool) != true,
               let text = promptText(obj) {
                headPrompts += 1
                if firstPrompt == nil { firstPrompt = text }
            }
        }

        // Provenance comes from byte markers, which means it depends on the
        // CLI's exact wire format. If a version bump ever moves that ground,
        // fall back to what parsing found and stay permissive: an extra row is
        // a smaller failure than a picker that lists nothing.
        var counted = provenance(of: url)
        if counted.prompts == 0, headPrompts > 0 {
            counted = (human: headPrompts, sdk: 0, prompts: headPrompts)
        }

        // A compacted conversation gets a real summary from the CLI, which
        // beats "continue" as a title. It lands late in the file, so look last.
        var summary: String?
        for line in tailLines(of: url, bytes: 128 * 1024) {
            guard let obj = json(line) else { continue }
            // the branch a long session ENDED on is the one you'd recognize it
            // by — sessions outlive the branch they were opened on
            if let b = obj["gitBranch"] as? String, !b.isEmpty, b != "HEAD" { branch = b }
            switch obj["type"] as? String {
            case "ai-title": summary = (obj["aiTitle"] as? String) ?? summary
            case "summary":  summary = (obj["summary"] as? String) ?? summary
            default: break
            }
        }

        let title = [summary, firstPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "untitled conversation"

        return Conversation(id: id,
                            fileURL: url,
                            title: String(title.prefix(120)),
                            lastActivity: modified(url),
                            prompts: counted.prompts,
                            humanTyped: counted.human > 0,
                            gitBranch: branch,
                            fromBob: fromBob)
    }

    /// Who was doing the talking, counted over the whole file in one pass.
    ///
    /// Reading every line as JSON to learn this would be minutes across a
    /// project's history; these markers are distinctive enough to find in the
    /// bytes. Tool results — the overwhelming bulk of a coding transcript —
    /// carry no `promptSource` at all, so they can't inflate the count.
    static func provenance(of url: URL) -> (human: Int, sdk: Int, prompts: Int) {
        let origin = Data("\"origin\":{\"kind\":\"human\"}".utf8)
        let typed = Data("\"promptSource\":\"typed\"".utf8)
        let sdk = Data("\"promptSource\":\"sdk\"".utf8)
        let counts = scan(url, for: [origin, typed, sdk])
        // older transcripts predate `origin` and only carry promptSource, so
        // take whichever marker saw more rather than assuming both exist
        let human = max(counts[0], counts[1])
        return (human, counts[2], human + counts[2])
    }

    /// Count needle occurrences in one streaming pass. Matches are deduped by
    /// absolute file offset: consecutive windows deliberately overlap so a
    /// marker split across two reads is still found, which would otherwise
    /// count the short needles inside that overlap twice.
    private static func scan(_ url: URL, for needles: [Data]) -> [Int] {
        var counts = [Int](repeating: 0, count: needles.count)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return counts }
        defer { try? handle.close() }

        let overlap = max(0, (needles.map(\.count).max() ?? 1) - 1)
        var lastEnd = [Int](repeating: Int.min, count: needles.count)
        var carry = Data()
        var windowStart = 0            // absolute offset of carry's first byte

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            var window = carry
            window.append(chunk)
            for (i, needle) in needles.enumerated() {
                var from = window.startIndex
                while let found = window.range(of: needle, in: from..<window.endIndex) {
                    let absolute = windowStart + window.distance(from: window.startIndex, to: found.lowerBound)
                    if absolute >= lastEnd[i] {
                        counts[i] += 1
                        lastEnd[i] = absolute + needle.count
                    }
                    from = found.upperBound
                }
            }
            windowStart += window.count - overlap
            carry = Data(window.suffix(overlap))
        }
        return counts
    }

    // MARK: - reading one back

    /// The chosen conversation as transcript rows. Bounded from the end: a long
    /// conversation shows its recent shape, which is what you need to recognize
    /// where you left off — the model still has the whole thing, since resuming
    /// hands history to the CLI, not to us.
    static func history(of url: URL, maxTurns: Int = 120, tailBytes: Int = 4 << 20) -> [Turn] {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let lines = size > tailBytes ? tailLines(of: url, bytes: tailBytes) : allLines(of: url)
        var turns: [Turn] = []
        for line in lines {
            guard let obj = json(line),
                  (obj["isSidechain"] as? Bool) != true,
                  (obj["isMeta"] as? Bool) != true
            else { continue }
            switch obj["type"] as? String {
            case "user":
                if let text = promptText(obj) { turns.append(Turn(fromYou: true, text: text)) }
            case "assistant":
                if let text = assistantText(obj) { turns.append(Turn(fromYou: false, text: text)) }
            default:
                break
            }
        }
        return turns.suffix(maxTurns)
    }

    // MARK: - message text

    /// A user entry's actual words, or nil when the entry isn't conversation:
    /// tool results, interface chrome, and the hidden notes bob slips into its
    /// own thread (attention digests, minion debriefs) all read as `user` on
    /// disk but were never something the owner said.
    static func promptText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        var text: String?
        if let s = message["content"] as? String {
            text = s
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        }
        return conversational(text)
    }

    private static func assistantText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return nil }
        let said = blocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return conversational(said)
    }

    /// Strips what isn't conversation. The `<` and `Caveat:` cases are the
    /// CLI's own interface chrome; the bracketed ones are bob's hidden layer.
    private static func conversational(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        for chrome in ["<", "Caveat:", "[Request interrupted", "[system note"] where t.hasPrefix(chrome) {
            return nil
        }
        return t
    }

    // MARK: - bytes

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whole lines from the front. The final fragment is dropped — a transcript
    /// being written to right now ends mid-line, and half a line is not data.
    private static func headLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return [] }
        var lines = split(data)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > bytes, !lines.isEmpty { lines.removeLast() }
        return lines
    }

    /// Whole lines from the end, first fragment dropped for the same reason.
    private static func tailLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let offset = max(0, size - bytes)
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        var lines = split(data)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func allLines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return split(data)
    }

    private static func split(_ data: Data) -> [String] {
        (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}
