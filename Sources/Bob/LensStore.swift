import Foundation

/// One assembled lens, ready to hand to `claude --append-system-prompt`.
struct LensContext {
    /// Normalized spec — `music`, or `project:lootgo` for a parameterized lens.
    let name: String
    let text: String
    let approxTokens: Int
    let fileCount: Int
}

/// Reads `~/bob/lenses/<name>.md`, expands its file list, trims to the lens's
/// token budget and assembles the block bob injects into claude's system prompt.
///
/// Deliberately **not** `@MainActor` — the open line and minion spawn resolve
/// lenses from detached tasks. All mutable state is behind one lock.
final class LensStore {
    static let shared = LensStore()

    /// Budget when a lens omits `budget:`.
    static let defaultBudget = 4000
    /// Hard clamp — no lens gets to eat the context window.
    static let maxBudget = 12000
    /// chars-per-token estimate (`utf8Bytes / 4`).
    static let bytesPerToken = 4

    private let root: URL
    private let lock = NSLock()
    private var cache: [String: CachedLens] = [:]

    /// `root` is bob's home. The parameter exists for tests; production is `~/bob`.
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob", isDirectory: true)
    }

    // MARK: api

    /// `"music"` or `"project:lootgo"`. Returns nil on any failure — callers
    /// then send with no `--append-system-prompt` at all (today's behavior).
    /// Every outcome, good or bad, lands in `state/lens-debug.log`.
    func resolve(_ spec: String) -> LensContext? {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // spec splits into (name, arg) on the FIRST colon
        var name = trimmed
        var arg: String? = nil
        if let colon = trimmed.firstIndex(of: ":") {
            name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            arg = rest.isEmpty ? nil : rest
        }
        let display = arg.map { "\(name):\($0)" } ?? name

        guard isSafe(name) else { log("lens '\(display)' failed: bad lens name"); return nil }
        if let arg, !isSafe(arg) { log("lens '\(display)' failed: bad argument"); return nil }

        let path = lensesDir.appendingPathComponent("\(name).md")
        guard let lens = parsedLens(at: path) else {
            log("lens '\(display)' failed: no lenses/\(name).md")
            return nil
        }
        if lens.needsArg && arg == nil {
            log("lens '\(display)' failed: lens takes an argument (@\(name):<arg>)")
            return nil
        }

        let stance = substitute(lens.stance, arg)
        let selectors = lens.files.map { substitute($0, arg) }
        let budget = max(0, min(lens.budget, Self.maxBudget))

        // priority order, deduped; missing matches drop out silently
        var wanted: [String] = []
        var seen = Set<String>()
        for selector in selectors {
            for rel in expand(selector) where !seen.contains(rel) {
                seen.insert(rel)
                wanted.append(rel)
            }
        }

        let header = "# lens: \(display) — assembled by bob's swift layer (budget \(budget) tokens)\n"
            + "the file sections below are already loaded — do NOT re-read these paths this turn.\n"

        let budgetBytes = budget * Self.bytesPerToken
        var usedBytes = header.utf8.count + stance.utf8.count + 2
        var body = ""
        var loaded = 0
        var overBudget: [String] = []

        var i = 0
        while i < wanted.count {
            let rel = wanted[i]
            guard let contents = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else {
                i += 1                                  // vanished between glob and read
                continue
            }
            let section = "\n## \(rel)\n" + (contents.hasSuffix("\n") ? contents : contents + "\n")
            let cost = section.utf8.count

            if usedBytes + cost <= budgetBytes {
                body += section
                usedBytes += cost
                loaded += 1
                i += 1
                continue
            }

            // doesn't fit whole — truncate if at least a quarter of it would
            let room = max(0, budgetBytes - usedBytes)
            if room >= cost / 4, let cut = truncated(rel: rel, contents: contents, roomBytes: room) {
                body += cut.text
                usedBytes += cut.bytes
                loaded += 1
                overBudget = Array(wanted[(i + 1)...])
                break
            }

            overBudget = Array(wanted[i...])
            break
        }

        var text = header
        if !stance.isEmpty { text += "\n" + stance + "\n" }
        text += body
        overBudget = overBudget.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        if !overBudget.isEmpty {
            text += "\n[not loaded (over budget) — read if needed: \(overBudget.joined(separator: ", "))]\n"
        }

        let approxTokens = text.utf8.count / Self.bytesPerToken
        log("lens '\(display)' assembled: \(loaded) file\(loaded == 1 ? "" : "s"), ~\(approxTokens) tokens")
        return LensContext(name: display, text: text, approxTokens: approxTokens, fileCount: loaded)
    }

    /// Lens names on disk — for the chip and any future autocomplete.
    func lensNames() -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: lensesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    var lensesDir: URL { root.appendingPathComponent("lenses", isDirectory: true) }

    // MARK: parsing (cached by path + mtime)

    private struct ParsedLens {
        let budget: Int
        let files: [String]
        let stance: String
        let needsArg: Bool
    }

    private struct CachedLens {
        let mtime: Date
        let lens: ParsedLens
    }

    private func parsedLens(at url: URL) -> ParsedLens? {
        let fm = FileManager.default
        guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else {
            return nil
        }
        lock.lock()
        let hit = cache[url.path]
        lock.unlock()
        if let hit, hit.mtime == mtime { return hit.lens }

        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lens = parse(raw)
        lock.lock()
        cache[url.path] = CachedLens(mtime: mtime, lens: lens)
        lock.unlock()
        return lens
    }

    /// Hand-rolled frontmatter: exactly `budget: <int>` and a `files:` dash-list.
    /// Everything after the closing `---` is the stance, injected verbatim.
    private func parse(_ raw: String) -> ParsedLens {
        var budget = Self.defaultBudget
        var files: [String] = []
        var stance = raw

        let lines = raw.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var inFiles = false
            var i = 1
            var closed = false
            while i < lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
                if line == "---" { closed = true; break }
                if inFiles, line.hasPrefix("- ") {
                    let path = String(line.dropFirst(2))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !path.isEmpty { files.append(path) }
                } else if line.hasPrefix("budget:") {
                    inFiles = false
                    if let n = Int(String(line.dropFirst("budget:".count)).trimmingCharacters(in: .whitespaces)) {
                        budget = n
                    }
                } else if line.hasPrefix("files:") {
                    inFiles = true
                } else if !line.isEmpty {
                    inFiles = false                      // unknown key ends the list
                }
            }
            stance = closed ? lines[i...].joined(separator: "\n") : ""
        }

        stance = stance.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsArg = stance.contains("{arg}") || files.contains { $0.contains("{arg}") }
        return ParsedLens(budget: budget, files: files, stance: stance, needsArg: needsArg)
    }

    private func substitute(_ s: String, _ arg: String?) -> String {
        guard let arg else { return s }
        return s.replacingOccurrences(of: "{arg}", with: arg)
    }

    /// No absolute paths, no `..` escapes out of bob's home.
    private func isSafe(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.contains("/") || token.contains("..") { return false }
        return true
    }

    // MARK: selectors

    /// Expands one `files:` entry (relative to bob's home, `*`/`?` allowed) into
    /// existing regular-file paths, sorted for determinism. Non-matches → `[]`.
    private func expand(_ selector: String) -> [String] {
        var rel = selector.trimmingCharacters(in: .whitespaces)
        if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
        guard !rel.isEmpty, !rel.hasPrefix("/"),
              !rel.components(separatedBy: "/").contains("..") else { return [] }

        let fm = FileManager.default
        let isGlob = rel.contains("*") || rel.contains("?")
        if !isGlob {
            var isDir: ObjCBool = false
            let path = root.appendingPathComponent(rel).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return [] }
            return [rel]
        }

        let comps = rel.components(separatedBy: "/")
        var baseComps: [String] = []
        for c in comps {
            if c.contains("*") || c.contains("?") { break }
            baseComps.append(c)
        }
        let baseDir = baseComps.isEmpty ? root : root.appendingPathComponent(baseComps.joined(separator: "/"))
        let shallow = baseComps.count == comps.count - 1     // glob only in the filename

        var candidates: [URL] = []
        if shallow {
            candidates = (try? fm.contentsOfDirectory(
                at: baseDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            )) ?? []
        } else if let en = fm.enumerator(
            at: baseDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in en { candidates.append(url) }
        }

        let prefix = root.standardizedFileURL.path + "/"
        var out: [String] = []
        for url in candidates {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let candidate = String(path.dropFirst(prefix.count))
            if fnmatch(rel, candidate, FNM_PATHNAME) == 0 { out.append(candidate) }
        }
        return out.sorted()
    }

    // MARK: budget trimming

    /// Line-boundary truncation with the `[... trimmed ...]` marker. Nil when not
    /// even one line fits in `roomBytes`.
    private func truncated(rel: String, contents: String, roomBytes: Int) -> (text: String, bytes: Int)? {
        let head = "\n## \(rel)\n"
        let markerReserve = 80                              // the trimmed-marker line
        var used = head.utf8.count + markerReserve
        guard used < roomBytes else { return nil }

        var lines = contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }          // trailing newline artifact
        let total = lines.count
        var shown = 0
        for line in lines {
            let cost = line.utf8.count + 1
            if used + cost > roomBytes { break }
            used += cost
            shown += 1
        }
        guard shown > 0, shown < total else { return nil }

        let text = head + lines.prefix(shown).joined(separator: "\n") + "\n"
            + "[... trimmed by lens budget — \(shown) of \(total) lines shown]\n"
        return (text, text.utf8.count)
    }

    // MARK: audit log

    private var logURL: URL { root.appendingPathComponent("state/lens-debug.log") }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let url = logURL
        lock.lock()
        defer { lock.unlock() }
        if fm.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
