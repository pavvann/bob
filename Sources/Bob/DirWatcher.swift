import Foundation

/// Push, not poll.
///
/// One FSEvents stream over the two roots bob reads — `~/bob` and `~/.claude` —
/// fanning changed paths out to whoever registered a prefix. FSEvents' own
/// latency window is the debounce: a 150ms burst of writes arrives as one batch,
/// and a quiet filesystem costs nothing at all, which is the whole point.
///
/// Directory-tree stream, never a per-file descriptor watcher: todos, canvas
/// boards, notes and minion records are all written atomically, and an atomic
/// replace swaps the inode out from under an open descriptor — a watcher pinned
/// to a file goes deaf on the very first write it exists to see.
///
/// Subscriptions are ref-counted ids rather than onAppear/onDisappear pairs.
/// SwiftUI remounts views freely and promises nothing about the order, so a
/// paired appear/disappear can leave a live surface unwatched — or a dead one
/// still holding a watch, which is how `AgentWatcher` and `GitStatus` ended up
/// polling for the life of the app after their rail went away.
final class DirWatcher {
    static let shared = DirWatcher()

    /// The changed paths under a subscriber's prefix, delivered on `queue`.
    /// Subscribers read and decode there; only an `==`-guarded publish crosses
    /// to the main actor.
    typealias Handler = ([String]) -> Void

    /// FSEvents coalesces everything inside this window into one callback.
    private static let debounce: CFTimeInterval = 0.15

    private let queue = DispatchQueue(label: "bob.dirwatcher", qos: .utility)

    private struct Sub {
        let prefix: String
        let floor: TimeInterval
        let handler: Handler
        var refs: Int
        var lastFired = Date.distantPast
        var held: [String] = []
        var scheduled = false
    }

    /// Both dictionaries and the stream are only ever touched on `queue`, which
    /// is serial — no locks anywhere in here.
    private var subs: [String: Sub] = [:]
    private var stream: FSEventStreamRef?

    private init() {}

    // MARK: - subscriptions

    /// Watch everything at or under `path`. `id` names the subscription so a
    /// second acquire ref-counts instead of replacing: two surfaces can want the
    /// same watch, and the first one leaving must not blind the second.
    ///
    /// `floor` is the minimum gap between handler runs. A streaming transcript
    /// appends dozens of times a second and a rescan per append would cost more
    /// than the poll being replaced; the floor coalesces those down to the rate
    /// the poll ran at, while a quiet directory still answers within one
    /// debounce.
    func acquire(path: String, id: String, floor: TimeInterval = 0, handler: @escaping Handler) {
        let prefix = Self.normalize(path)
        queue.async {
            if var sub = self.subs[id] {
                sub.refs += 1
                self.subs[id] = sub
                return
            }
            self.subs[id] = Sub(prefix: prefix, floor: floor, handler: handler, refs: 1)
            self.startIfNeeded()
        }
    }

    func release(id: String) {
        queue.async {
            guard var sub = self.subs[id] else { return }
            sub.refs -= 1
            if sub.refs > 0 { self.subs[id] = sub } else { self.subs.removeValue(forKey: id) }
        }
    }

    // MARK: - the stream

    /// The stream outlives every individual subscription: bob always has
    /// permanent subscribers (todos, notes, canvas, minions, sessions), and an
    /// idle FSEvents stream costs nothing — the kernel only speaks when the
    /// filesystem does.
    private func startIfNeeded() {
        guard stream == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [home.appendingPathComponent("bob"), home.appendingPathComponent(".claude")]
            .map { Self.normalize($0.path) }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<DirWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.fanOut(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        guard let created = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.debounce,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    /// Route one debounced batch. Matching runs in both directions: FSEvents
    /// collapses a busy subtree into its parent directory under load, so a
    /// subscriber on `state/todos.json` still has to wake for an event on
    /// `state`.
    private func fanOut(_ paths: [String]) {
        let now = Date()
        for (id, held) in subs {
            let hits = paths.filter { Self.related(Self.trimmed($0), held.prefix) }
            guard !hits.isEmpty else { continue }
            var sub = held
            sub.held.append(contentsOf: hits)
            let gap = now.timeIntervalSince(sub.lastFired)
            if gap >= sub.floor {
                let batch = sub.held
                sub.held = []
                sub.lastFired = now
                subs[id] = sub
                sub.handler(batch)
            } else if !sub.scheduled {
                sub.scheduled = true
                subs[id] = sub
                queue.asyncAfter(deadline: .now() + (sub.floor - gap)) { [weak self] in
                    self?.fire(id)
                }
            } else {
                subs[id] = sub
            }
        }
    }

    private func fire(_ id: String) {
        guard var sub = subs[id] else { return }
        sub.scheduled = false
        let batch = sub.held
        sub.held = []
        sub.lastFired = Date()
        subs[id] = sub
        guard !batch.isEmpty else { return }
        sub.handler(batch)
    }

    // MARK: - path matching

    /// Resolved and slash-trimmed. FSEvents reports real paths, so a prefix
    /// built from a symlinked home would never match one.
    private static func normalize(_ path: String) -> String {
        trimmed(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private static func trimmed(_ path: String) -> String {
        var out = path
        while out.count > 1, out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// True when either path contains the other. The boundary check is what
    /// keeps `notes-old/x` out of a `notes` subscription.
    private static func related(_ path: String, _ prefix: String) -> Bool {
        contains(prefix, path) || contains(path, prefix)
    }

    private static func contains(_ outer: String, _ inner: String) -> Bool {
        guard inner.hasPrefix(outer) else { return false }
        if inner.count == outer.count { return true }
        return inner[inner.index(inner.startIndex, offsetBy: outer.count)] == "/"
    }
}
