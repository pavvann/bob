import Foundation

actor ProjectScanner {
    struct Project: Sendable {
        let name: String
        let realPath: URL?
        let historyDir: URL?
        let sessionCount: Int
        let lastActivity: Date?
        let snippet: String?
        let category: Category
    }

    enum Category: Sendable {
        case active     // has code + history
        case codeOnly   // has code, no history
        case orphaned   // history but no code
    }

    private let home: URL
    private let codeDir: URL
    private let claudeProjectsDir: URL
    private let pathEncodingPrefix: String

    init(home: URL) {
        self.home = home
        self.codeDir = home.appendingPathComponent("Code", isDirectory: true)
        self.claudeProjectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        // Claude Code encodes project paths by replacing "/" with "-".
        // ~/Code → "-<components-joined-by-dash>-". Computed at runtime so
        // the app doesn't carry the current user's name as a hardcoded string.
        let components = codeDir.path
            .split(separator: "/")
            .map(String.init)
        self.pathEncodingPrefix = "-" + components.joined(separator: "-") + "-"
    }

    func scan() async -> [Project] {
        let codeProjects = enumerateCodeProjects()
        let histories = enumerateHistories()

        var byKey: [String: Project] = [:]

        // 1) Start from histories — they may resolve to nested code paths.
        for (encodedSuffix, history) in histories {
            let resolved = resolveRealPath(forEncodedSuffix: encodedSuffix)
            let displayName: String
            if let resolved {
                displayName = resolved.path.replacingOccurrences(of: codeDir.path + "/", with: "")
            } else {
                displayName = encodedSuffix
            }

            let snippet = resolved.flatMap { readSnippet(at: $0) }
            let category: Category = (resolved != nil) ? .active : .orphaned

            byKey[displayName] = Project(
                name: displayName,
                realPath: resolved,
                historyDir: history.url,
                sessionCount: history.sessions,
                lastActivity: history.lastActivity,
                snippet: snippet,
                category: category
            )
        }

        // 2) Add code projects with no matching history (codeOnly).
        for (name, url) in codeProjects {
            guard byKey[name] == nil else { continue }
            // Also check nested versions weren't already claimed by a history match.
            let alreadyClaimed = byKey.values.contains { $0.realPath?.path == url.path }
            if alreadyClaimed { continue }

            byKey[name] = Project(
                name: name,
                realPath: url,
                historyDir: nil,
                sessionCount: 0,
                lastActivity: nil,
                snippet: readSnippet(at: url),
                category: .codeOnly
            )
        }

        return byKey.values.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.name < rhs.name
            }
        }
    }

    // MARK: enumeration

    private func enumerateCodeProjects() -> [String: URL] {
        let fm = FileManager.default
        var out: [String: URL] = [:]
        guard let entries = try? fm.contentsOfDirectory(at: codeDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return out
        }
        for url in entries {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !url.lastPathComponent.hasPrefix(".") else { continue }
            out[url.lastPathComponent] = url
        }
        return out
    }

    private struct HistoryEntry { let url: URL; let sessions: Int; let lastActivity: Date? }

    private func enumerateHistories() -> [String: HistoryEntry] {
        let fm = FileManager.default
        var out: [String: HistoryEntry] = [:]
        guard let entries = try? fm.contentsOfDirectory(at: claudeProjectsDir, includingPropertiesForKeys: nil) else {
            return out
        }
        for url in entries {
            let raw = url.lastPathComponent
            guard raw.hasPrefix(pathEncodingPrefix) else { continue }
            let suffix = String(raw.dropFirst(pathEncodingPrefix.count))
            guard !suffix.isEmpty else { continue }

            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let sessions = children.filter { $0.pathExtension == "jsonl" }.count

            // most recent mtime across the dir's children, fallback to dir mtime
            var lastActivity: Date? = nil
            for child in children {
                if let attrs = try? fm.attributesOfItem(atPath: child.path),
                   let date = attrs[.modificationDate] as? Date {
                    if lastActivity == nil || date > lastActivity! { lastActivity = date }
                }
            }
            if lastActivity == nil,
               let attrs = try? fm.attributesOfItem(atPath: url.path) {
                lastActivity = attrs[.modificationDate] as? Date
            }

            out[suffix] = HistoryEntry(url: url, sessions: sessions, lastActivity: lastActivity)
        }
        return out
    }

    // MARK: path decoding (handles nested dirs like ~/Code/fkol/creatorapp)

    private func resolveRealPath(forEncodedSuffix suffix: String) -> URL? {
        let fm = FileManager.default
        let parts = suffix.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }

        // 1) Flat: ~/Code/<suffix-with-hyphens-intact>
        let flat = codeDir.appendingPathComponent(suffix)
        if fm.fileExists(atPath: flat.path) { return flat }

        // 2) One slash: ~/Code/<parts[0..i]-joined>/<parts[i...]-joined>
        if parts.count >= 2 {
            for i in 1..<parts.count {
                let parent = parts[0..<i].joined(separator: "-")
                let child = parts[i..<parts.count].joined(separator: "-")
                let nested = codeDir.appendingPathComponent(parent).appendingPathComponent(child)
                if fm.fileExists(atPath: nested.path) { return nested }
            }
        }

        // 3) Two slashes: ~/Code/<a>/<b>/<c>
        if parts.count >= 3 {
            for i in 1..<parts.count - 1 {
                for j in (i + 1)..<parts.count {
                    let a = parts[0..<i].joined(separator: "-")
                    let b = parts[i..<j].joined(separator: "-")
                    let c = parts[j..<parts.count].joined(separator: "-")
                    let nested = codeDir.appendingPathComponent(a).appendingPathComponent(b).appendingPathComponent(c)
                    if fm.fileExists(atPath: nested.path) { return nested }
                }
            }
        }

        return nil
    }

    // MARK: snippets

    private func readSnippet(at url: URL) -> String? {
        let fm = FileManager.default

        // 1) README.md — first non-empty, non-heading, non-badge line.
        let readme = url.appendingPathComponent("README.md")
        if let content = try? String(contentsOf: readme, encoding: .utf8) {
            for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("![") || line.hasPrefix("[![") { continue }
                if line.hasPrefix("<") { continue }
                return String(line.prefix(140))
            }
        }

        // 2) package.json description.
        let pkg = url.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let desc = json["description"] as? String, !desc.isEmpty {
                return String(desc.prefix(140))
            }
        }

        // 3) Cargo.toml description or pyproject.toml description — quick & dirty grep.
        for fname in ["Cargo.toml", "pyproject.toml"] {
            let f = url.appendingPathComponent(fname)
            if let content = try? String(contentsOf: f, encoding: .utf8) {
                for raw in content.split(separator: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("description") {
                        if let eq = line.firstIndex(of: "=") {
                            var rest = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            if !rest.isEmpty { return String(rest.prefix(140)) }
                        }
                    }
                }
            }
        }

        // 4) fallback: top-level visible files.
        if let entries = try? fm.contentsOfDirectory(atPath: url.path) {
            let visible = entries.filter { !$0.hasPrefix(".") }.sorted().prefix(6)
            if !visible.isEmpty {
                return "files: " + visible.joined(separator: ", ")
            }
        }

        return nil
    }
}
