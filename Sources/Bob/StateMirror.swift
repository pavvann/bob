import Foundation

/// The `~/bob/state/*.json` mirrors claude reads, written in the order they were
/// handed over.
///
/// Getting these writes off the main actor is the easy half. The hard half is
/// that a detached task per event can also *finish* out of order — two track
/// changes a moment apart, and `music.json` ends up describing the older one
/// while the tile shows the newer. So: one serial queue for all four mirrors.
///
/// A queue and not an actor, deliberately. An actor serializes *execution*, but
/// what's at stake here is *arrival*: two independently spawned tasks reach an
/// actor in whatever order the scheduler feels like. `async` on a serial queue
/// enqueues at the call site, so call order is write order.
enum StateMirror {
    private static let queue = DispatchQueue(label: "bob.state-mirror", qos: .utility)

    /// Encode and atomically replace, off the caller's thread. The encode rides
    /// along on the queue — it's the same few hundred bytes either way, and the
    /// main actor has better things to do.
    static func write<T: Encodable & Sendable>(_ value: T, to url: URL) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
