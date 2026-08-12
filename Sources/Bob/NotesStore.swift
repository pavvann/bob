import Foundation

/// pawan's own scratch notes — one markdown file per note in `~/bob/notes/`.
/// Same shape as TodoService: the file on disk is the truth, the swift layer
/// polls it (700ms) and writes back. bob appends to a note mid-conversation by
/// editing the file; the poll picks it up with no extra plumbing.
///
/// The one hard rule: **a poll never eats an unsaved edit.** While the buffer
/// is dirty an external change only raises `conflict` — the surface whispers
/// it, and the next save wins.
@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    struct Note: Identifiable, Equatable {
        /// The filename — `ideas.md`. Notes have no identity beyond their path.
        let id: String
        /// First `# ` heading, else the filename without `.md`.
        let title: String
        let modified: Date
    }

    /// mtime desc — the note touched last sits first.
    @Published private(set) var notes: [Note] = []
    /// Filename of the open note; nil when there's nothing to show.
    @Published private(set) var openID: String?
    /// The open note's text. The surface writes through `edit(_:)`, never here.
    @Published private(set) var text: String = ""
    /// Set between an edit and the debounced write landing.
    @Published private(set) var isDirty = false
    /// "ideas.md changed on disk — yours wins on save", else nil. The surface
    /// whispers this; it clears itself on the next save or note switch.
    @Published private(set) var conflict: String?

    let dir: URL

    /// What we last read from — or wrote to — disk for the open note. The
    /// difference between this and the file is what "changed on disk" means.
    private var diskText: String = ""
    private var titles: [String: (mtime: Date, title: String)] = [:]
    private var pollTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private static let pollInterval: UInt64 = 700_000_000
    private static let saveDelay: UInt64 = 500_000_000

    /// `dir` is an override for tests; production is `~/bob/notes/`.
    init(dir: URL? = nil) {
        self.dir = dir ?? BobHome.shared.notesDir
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        reload()
        startPolling()
    }

    deinit {
        pollTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: api

    var openNote: Note? { notes.first { $0.id == openID } }

    /// Switch notes. Whatever was in the buffer is written first.
    func open(_ id: String) {
        guard id != openID else { return }
        flush()
        adopt(id)
    }

    /// Every keystroke from the surface. Marks dirty, schedules the write.
    func edit(_ new: String) {
        guard openID != nil, new != text else { return }
        text = new
        isDirty = true
        scheduleSave()
    }

    /// Creates `notes/<kebab-title>.md` carrying an `# title` heading and opens
    /// it. Returns the filename, nil if the write failed.
    @discardableResult
    func create(titled raw: String) -> String? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = uniqueFilename(for: title)
        let body = title.isEmpty ? "" : "# \(title)\n\n"
        do {
            try body.write(to: dir.appendingPathComponent(id), atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        flush()
        reload()
        open(id)
        return id
    }

    /// Write now — leaving a note, closing the surface, quitting.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, let id = openID, let data = text.data(using: .utf8) else { return }
        // did the file move under us while the buffer was dirty? his version
        // still wins — but he gets told, rather than losing bob's line silently.
        let drifted = (read(id) ?? diskText) != diskText
        do {
            try data.write(to: dir.appendingPathComponent(id), options: .atomic)
        } catch {
            return                              // stays dirty; the next edit retries
        }
        diskText = text
        isDirty = false
        conflict = drifted ? "\(id) had changed on disk — your version won" : nil
        reload()
    }

    /// One pass over the directory and the open note. The poll calls this every
    /// 700ms; the surface can force it on appear.
    func reload() {
        let listed = list()
        if listed != notes { notes = listed }

        guard let id = openID else {
            if let first = notes.first { adopt(first.id) }
            return
        }
        guard let disk = read(id) else {
            // the file went away under us — bob renamed it, or finder did
            if isDirty {
                conflict = "\(id) is gone from disk — saving puts it back"
            } else {
                openID = nil
                if let first = notes.first { adopt(first.id) }
            }
            return
        }
        guard disk != diskText else { return }  // nothing new on disk
        if isDirty {
            conflict = "\(id) changed on disk — yours wins on save"
        } else {
            text = disk
            diskText = disk
        }
    }

    // MARK: title / filename derivation

    /// Title = the first `# ` heading, else the filename. Frontmatter isn't
    /// required, but if bob or pawan wrote some it's skipped, not rendered.
    static func title(of contents: String, filename: String) -> String {
        var lines = contents.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            lines = Array(lines[(close + 1)...])
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return filename.hasSuffix(".md") ? String(filename.dropLast(3)) : filename
    }

    /// "Bob's Canvas Ideas!" → "bobs-canvas-ideas". Empty → "note".
    static func kebab(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch == "'" || ch == "\u{2019}" {
                continue                        // apostrophes vanish, not dash
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        out = String(out.prefix(48))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "note" : out
    }

    // MARK: disk

    private func list() -> [Note] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Note] = []
        for url in urls where url.pathExtension == "md" {
            let name = url.lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // titles are cached by mtime — the poll shouldn't re-read every
            // note every 700ms just to find its heading.
            let title: String
            if let hit = titles[name], hit.mtime == mtime {
                title = hit.title
            } else {
                title = Self.title(of: (try? String(contentsOf: url, encoding: .utf8)) ?? "", filename: name)
                titles[name] = (mtime, title)
            }
            out.append(Note(id: name, title: title, modified: mtime))
        }
        return out.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }

    private func read(_ id: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(id), encoding: .utf8)
    }

    /// Take a note as the open one, buffer clean. No flush — callers do that.
    private func adopt(_ id: String) {
        guard let disk = read(id) else { return }
        openID = id
        text = disk
        diskText = disk
        isDirty = false
        conflict = nil
    }

    private func uniqueFilename(for title: String) -> String {
        let stem = Self.kebab(title)
        let fm = FileManager.default
        var candidate = "\(stem).md"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stem)-\(n).md"
            n += 1
        }
        return candidate
    }

    // MARK: timing

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                self?.reload()
            }
        }
    }

    /// Typing shouldn't hit the disk on every keystroke — one write, half a
    /// second after you stop.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
