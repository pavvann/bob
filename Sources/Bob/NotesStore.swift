import Foundation

/// pawan's own scratch notes — one markdown file per note in `~/bob/notes/`.
/// Same shape as TodoService: the file on disk is the truth, the swift layer
/// watches the directory and writes back. bob appends to a note mid-conversation
/// by editing the file; the watcher picks it up with no extra plumbing.
///
/// The one hard rule: **a scan never eats an unsaved edit.** While the buffer
/// is dirty an external change only raises `conflict` — the surface whispers
/// it, and the next save wins.
///
/// The open note is re-read only when its mtime has actually moved. The old
/// 700ms poll re-read it unconditionally, which made an untouched notes surface
/// the app's busiest reader for no information at all.
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
    /// The mtime `diskText` came from — the gate on re-reading the open note.
    private var diskMtime: Date?
    private var titles: [String: TitleCache] = [:]
    private var saveTask: Task<Void, Never>?

    private struct TitleCache: Sendable {
        let mtime: Date
        let title: String
    }

    /// One pass over the directory, plus the open note if and only if it moved.
    private struct Scan: Sendable {
        var notes: [Note]
        var titles: [String: TitleCache]
        /// Which note the scan was aimed at — a switch mid-scan invalidates it.
        var open: String?
        /// nil when the mtime hadn't moved, so there was nothing to read.
        var openText: String?
        var openMtime: Date?
        var openGone = false
    }

    private static let saveDelay: UInt64 = 500_000_000

    /// `dir` is an override for tests; production is `~/bob/notes/`.
    init(dir: URL? = nil) {
        self.dir = dir ?? BobHome.shared.notesDir
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        DirWatcher.shared.acquire(path: self.dir.path, id: "notes-\(self.dir.path)") { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    deinit {
        saveTask?.cancel()
        DirWatcher.shared.release(id: "notes-\(dir.path)")
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
        let url = dir.appendingPathComponent(id)
        // did the file move under us while the buffer was dirty? his version
        // still wins — but he gets told, rather than losing bob's line silently.
        let drifted = (Self.read(url) ?? diskText) != diskText
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return                              // stays dirty; the next edit retries
        }
        diskText = text
        // our own write moved the mtime — record it, or the next scan re-reads a
        // file it already has
        diskMtime = Self.mtime(url)
        isDirty = false
        conflict = drifted ? "\(id) had changed on disk — your version won" : nil
        reload()
    }

    /// One pass over the directory and, if it moved, the open note. The watcher
    /// calls this on a change; the surface can force it on appear.
    func reload() {
        let dir = self.dir
        let titles = self.titles
        let open = openID
        let known = diskMtime
        Task.detached(priority: .utility) { [weak self] in
            let scan = Self.scan(dir: dir, titles: titles, open: open, knownMtime: known)
            await self?.apply(scan)
        }
    }

    private func apply(_ scan: Scan) {
        titles = scan.titles
        if scan.notes != notes { notes = scan.notes }

        guard let id = openID else {
            if let first = notes.first { adopt(first.id) }
            return
        }
        // a note switch landed while the scan was in flight — it read the wrong
        // file, and the switch already adopted the right one
        guard scan.open == id else { return }
        if scan.openGone {
            // the file went away under us — bob renamed it, or finder did
            if isDirty {
                conflict = "\(id) is gone from disk — saving puts it back"
            } else {
                openID = nil
                if let first = notes.first { adopt(first.id) }
            }
            return
        }
        guard let disk = scan.openText else { return }  // mtime hadn't moved
        diskMtime = scan.openMtime
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
    nonisolated static func title(of contents: String, filename: String) -> String {
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
    nonisolated static func kebab(_ title: String) -> String {
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

    /// The whole disk pass, off the main actor: list the directory, and read the
    /// open note only when `knownMtime` disagrees with what's on disk.
    private nonisolated static func scan(
        dir: URL, titles: [String: TitleCache], open: String?, knownMtime: Date?
    ) -> Scan {
        var cache = titles
        var out: [Note] = []
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []

        var openMtime: Date?
        for url in urls where url.pathExtension == "md" {
            let name = url.lastPathComponent
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if name == open { openMtime = mtime }
            // titles are cached by mtime — a scan shouldn't re-read every note
            // just to find its heading.
            let title: String
            if let hit = cache[name], hit.mtime == mtime {
                title = hit.title
            } else {
                title = Self.title(of: (try? String(contentsOf: url, encoding: .utf8)) ?? "", filename: name)
                cache[name] = TitleCache(mtime: mtime, title: title)
            }
            out.append(Note(id: name, title: title, modified: mtime))
        }

        var scan = Scan(
            notes: out.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified },
            titles: cache,
            open: open
        )
        guard let open else { return scan }
        guard let openMtime else {
            scan.openGone = true
            return scan
        }
        guard openMtime != knownMtime else { return scan }
        scan.openMtime = openMtime
        scan.openText = read(dir.appendingPathComponent(open))
        if scan.openText == nil { scan.openGone = true }
        return scan
    }

    private nonisolated static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// A stat, not a read — what the open-note gate compares against.
    private nonisolated static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Take a note as the open one, buffer clean. No flush — callers do that.
    private func adopt(_ id: String) {
        let url = dir.appendingPathComponent(id)
        guard let disk = Self.read(url) else { return }
        openID = id
        text = disk
        diskText = disk
        diskMtime = Self.mtime(url)
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
