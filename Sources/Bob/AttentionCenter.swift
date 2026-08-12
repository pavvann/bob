import Foundation
import Combine

/// The manager's ear (plan D9). Watches every work session's status and, when
/// one flips into trouble — or quietly finishes while the owner is looking
/// elsewhere — folds a ≤300-char digest into the COMPANION session as a hidden
/// user message. Bob-the-model relays it in one line; the owner commands back
/// with `>name …`. Digests only, never transcripts: bob hears that lootgo's
/// tests went red, not the whole scrollback.
///
/// Delivery reuses the debrief gate's mechanics (ClaudeBridge.drainDebriefs):
/// notes land only when bob is idle, one per idle window, so his voice never
/// interleaves. Holding notes client-side is also what makes coalescing work —
/// a session that errors three times while bob is talking produces ONE note,
/// carrying the freshest digest, not a backlog of stale ones.
@MainActor
final class AttentionCenter {
    static let shared = AttentionCenter(manager: .shared)

    /// Why a note exists — wording differs, mechanics don't.
    enum Cue: Equatable {
        case attention   // errored turn, dropped process, dead session
        case finished    // a turn completed while the owner was elsewhere
    }

    private let manager: SessionManager
    private var registryWatch: AnyCancellable?
    private var sessionWatches: [UUID: AnyCancellable] = [:]
    /// Last seen machine state / derived status per session — transitions are
    /// the signal, standing states are not (a session that IS broken shouldn't
    /// re-announce itself every delta).
    private var lastState: [UUID: ClaudeSession.State] = [:]
    private var lastStatus: [UUID: SessionStatus] = [:]
    /// One undelivered note per session, in arrival order. A newer cue from the
    /// same session overwrites its note in place — that's the whole debounce.
    private var pending: [(id: UUID, note: String)] = []

    init(manager: SessionManager) {
        self.manager = manager
    }

    /// Idempotent — SessionManager calls this at launch, harnesses call it
    /// directly on their own manager.
    func start() {
        guard registryWatch == nil else { return }
        registryWatch = manager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.resubscribe() }
            }
        resubscribe()
    }

    /// One watch per live session, dropped when the session leaves the
    /// registry. The hop through the main queue matters: objectWillChange
    /// fires *before* a mutation lands, so the sink must run after the current
    /// main-actor job finishes — by then every property reads post-change.
    private func resubscribe() {
        let live = manager.sessions
        let liveIDs = Set(live.map(\.id))
        for id in sessionWatches.keys where !liveIDs.contains(id) {
            sessionWatches[id] = nil
            lastState[id] = nil
            lastStatus[id] = nil
            pending.removeAll { $0.id == id }
        }
        for session in live where sessionWatches[session.id] == nil {
            sessionWatches[session.id] = session.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session] _ in
                    guard let session else { return }
                    MainActor.assumeIsolated { self?.observe(session) }
                }
            observe(session)   // prime: current state is baseline, not news
        }
    }

    /// The companion's own changes only matter as the drain gate opening;
    /// work sessions get the full transition read.
    private func observe(_ session: ClaudeSession) {
        if session.id != manager.companionID { reevaluate(session) }
        drain()
    }

    private func reevaluate(_ session: ClaudeSession) {
        let state = session.state
        let status = SessionManager.status(of: session)
        let prevState = lastState[session.id]
        let prevStatus = lastStatus[session.id]
        lastState[session.id] = state
        lastStatus[session.id] = status
        guard prevStatus != nil else { return }   // first sight — baseline only

        let turnEnded: Bool
        if case .turnActive = prevState ?? .unspawned, state == .idle {
            turnEnded = true   // .interrupting → idle is the owner's own stop — not news
        } else {
            turnEnded = false
        }

        if (status == .needsAttention || status == .error), prevStatus != status {
            enqueue(session, cue: .attention, reason: badReason(session, status: status))
        } else if turnEnded, manager.activeID != session.id,
                  status == .done || status == .awaitingInput {
            // a notable done: it finished (or stopped on a question) while the
            // owner's eyes were on another stage. On the active stage he's
            // already watching — say nothing.
            enqueue(session, cue: .finished, reason: doneReason(session, status: status))
        }
    }

    /// What flipped it — the same evidence status derivation used, as words.
    private func badReason(_ session: ClaudeSession, status: SessionStatus) -> String {
        if status == .error { return session.lastError ?? "the session is down" }
        if let last = session.entries.last, last.role == .notice, last.taskId == nil {
            return last.text   // "session dropped — reconnecting" and kin
        }
        if let r = session.lastResult, r.isError {
            return r.text ?? "the last turn errored"
        }
        return "needs a look"
    }

    private func doneReason(_ session: ClaudeSession, status: SessionStatus) -> String {
        if let r = session.lastResult, !r.deniedTools.isEmpty {
            return "blocked — tools denied: \(r.deniedTools.joined(separator: ", "))"
        }
        return status == .awaitingInput ? "stopped on a question for the owner" : "finished its turn"
    }

    private func enqueue(_ session: ClaudeSession, cue: Cue, reason: String) {
        let note = Self.note(
            cue: cue,
            name: session.config.name,
            cwdTail: Self.cwdTail(session.config.cwd),
            digest: Self.digest(
                reason: reason,
                lastPrompt: session.entries.last(where: { $0.role == .you && !$0.hidden })?.text,
                lastReply: session.entries.last(where: { $0.role == .bob && !$0.text.isEmpty })?.text
            )
        )
        if let i = pending.firstIndex(where: { $0.id == session.id }) {
            pending[i].note = note   // coalesce — latest digest wins, place in line kept
        } else {
            pending.append((session.id, note))
        }
        drain()
    }

    /// The gate. One note per idle window: sending flips the companion to
    /// turnActive, so the next pending note waits for the next idle — each
    /// report is its own spoken turn, never interleaved.
    private func drain() {
        guard !pending.isEmpty,
              let companion = manager.companion, case .idle = companion.state
        else { return }
        let next = pending.removeFirst()
        companion.send(next.note, hidden: true, source: .injected)
    }

    // MARK: - digest building (pure — the harness proves the ≤300 promise)

    static func note(cue: Cue, name: String, cwdTail: String, digest: String) -> String {
        let verb = cue == .finished ? "finished" : "needs attention"
        return "[system note — not from the user] session '\(name)' (\(cwdTail)) \(verb): \(digest). tell the owner in one short line."
    }

    /// ≤300 characters, always. Reason first (it's why bob is being told),
    /// then one line each of what the owner asked and what the session last
    /// said — enough to relay, never enough to reconstruct.
    static func digest(reason: String, lastPrompt: String?, lastReply: String?) -> String {
        var parts = [clamp(reason, 140)]
        if let p = lastPrompt.flatMap(firstLine) { parts.append("owner asked \"\(clamp(p, 60))\"") }
        if let r = lastReply.flatMap(lastLine) { parts.append("it last said \"\(clamp(r, 60))\"") }
        return String(parts.joined(separator: " · ").prefix(300))
    }

    /// One line, hard-capped. Newlines become spaces before the cap so a
    /// multi-line error message still reads as a digest, not a stanza.
    static func clamp(_ text: String, _ cap: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count <= cap ? flat : String(flat.prefix(max(1, cap) - 1)) + "…"
    }

    /// A prompt's intent lives in its first line; a reply's conclusion in its last.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }

    static func cwdTail(_ cwd: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
