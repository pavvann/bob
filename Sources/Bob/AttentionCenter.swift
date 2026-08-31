import Foundation
import Combine

/// The manager's ear (plan D9). Watches every work session's status and, when
/// one flips into trouble — or quietly finishes while the owner is looking
/// elsewhere — folds a ≤300-char digest into the COMPANION session as a hidden
/// user message. Bob-the-model relays it in one line; the owner commands back
/// with `>name …`. Digests only, never transcripts: bob hears that webapp's
/// tests went red, not the whole scrollback.
///
/// Delivery reuses the debrief gate's mechanics (ClaudeBridge.drainDebriefs):
/// notes land only when bob is idle, one per idle window, so his voice never
/// interleaves. Holding notes client-side is also what makes coalescing work —
/// a session that errors three times while bob is talking produces ONE note,
/// carrying the freshest digest, not a backlog of stale ones.
///
/// Provider-blind by construction (#38). Everything below reads `AmbientSession`,
/// so a codex tab going red is the same event as a claude tab going red — the
/// only two things the two providers word differently are `troubleReason` and
/// `settledReason`, which each of them answers out of its own evidence at the
/// bottom of this file.
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
    private var sessionWatches: [UUID: Task<Void, Never>] = [:]
    /// Last seen phase / derived status per session — transitions are the
    /// signal, standing states are not (a session that IS broken shouldn't
    /// re-announce itself every delta).
    private var lastPhase: [UUID: AmbientPhase] = [:]
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
        // Both registries. `sessions` is claude's and `codexSessions` is codex's
        // — two lists because the bridge mirrors one of them — but a tab
        // arriving in either is a session the owner can be told about, so the
        // ear subscribes to the merge rather than to the claude half.
        registryWatch = Publishers.Merge(
            manager.$sessions.map { _ in () }.eraseToAnyPublisher(),
            manager.$codexSessions.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.resubscribe() }
        }
        resubscribe()
    }

    /// Every live session, either provider, the companion included — his idling
    /// is what opens the delivery gate. Private because the ear is the only
    /// thing that wants the two lists flattened; everything else in bob reads
    /// `workTabs`, which is ordered and excludes bob himself.
    private var liveSessions: [any AmbientSession] {
        (manager.sessions as [any AmbientSession]) + (manager.codexSessions as [any AmbientSession])
    }

    /// One watch per live session, dropped when the session leaves the
    /// registry. Sessions speak in `notes` — turn boundaries and health
    /// flips, never per delta — emitted after the mutation they describe, so
    /// every property reads post-change by the time the loop wakes.
    private func resubscribe() {
        let live = liveSessions
        let liveIDs = Set(live.map(\.id))
        for id in sessionWatches.keys where !liveIDs.contains(id) {
            sessionWatches.removeValue(forKey: id)?.cancel()
            lastPhase[id] = nil
            lastStatus[id] = nil
            pending.removeAll { $0.id == id }
        }
        for session in live where sessionWatches[session.id] == nil {
            let notes = session.notes
            sessionWatches[session.id] = Task { [weak self, weak session] in
                for await _ in notes {
                    guard let self, let session else { return }
                    self.observe(session)
                }
            }
            observe(session)   // prime: current state is baseline, not news
        }
    }

    /// The companion's own changes only matter as the drain gate opening;
    /// work sessions get the full transition read.
    private func observe(_ session: any AmbientSession) {
        if session.id != manager.companionID { reevaluate(session) }
        drain()
    }

    private func reevaluate(_ session: any AmbientSession) {
        let phase = session.ambientPhase
        let status = session.ambientStatus
        let prevPhase = lastPhase[session.id]
        let prevStatus = lastStatus[session.id]
        lastPhase[session.id] = phase
        lastStatus[session.id] = status
        guard prevStatus != nil else { return }   // first sight — baseline only

        // `.stopping → .settled` is the owner's own stop and is not news, which
        // is the whole reason AmbientPhase keeps stopping and working apart.
        let turnEnded = prevPhase == .working && phase == .settled

        if (status == .needsAttention || status == .error), prevStatus != status {
            enqueue(session, cue: .attention, reason: session.troubleReason(status))
        } else if turnEnded, manager.activeID != session.id,
                  status == .done || status == .awaitingInput {
            // a notable done: it finished (or stopped on a question) while the
            // owner's eyes were on another stage. On the active stage he's
            // already watching — say nothing.
            enqueue(session, cue: .finished, reason: session.settledReason(status))
        }
    }

    /// What the owner has to type to answer. A digest exists to be actioned with
    /// `>name`, and `dispatchKeys` qualifies a name two tabs share — so a note
    /// naming the bare `webapp` when the addressable key is `webapp/codex` is a
    /// doorbell with no door behind it. Falls back to the tab's own name for a
    /// tab that is addressable by nothing (two same-provider tabs in same-named
    /// directories), which is still worth saying out loud.
    private func address(of session: any AmbientSession) -> String {
        dispatchKeys(manager.workTabs).first { $0.value.id == session.id }?.key
            ?? session.displayName
    }

    private func enqueue(_ session: any AmbientSession, cue: Cue, reason: String) {
        let note = Self.note(
            cue: cue,
            name: address(of: session),
            cwdTail: Self.cwdTail(session.cwd),
            digest: Self.digest(
                reason: reason,
                lastPrompt: session.transcript.entries.last(where: { $0.role == .you && !$0.hidden })?.text,
                lastReply: session.transcript.entries.last(where: { $0.role == .bob && !$0.text.isEmpty })?.text
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

// MARK: - the two providers, in their own evidence
//
// The conformances live here rather than beside the `StageSession` ones because
// this is the only consumer and because what they answer is wording, not shape:
// the protocol is a seam, but "why does this need a look" is the ear's business.

extension ClaudeSession: AmbientSession {
    /// NOT derived from `phase`: that folds `.interrupting` into `.busy`, and an
    /// owner's stop would then read as a turn that ended. Mapped so the derived
    /// turn-end test is bit-identical to the `if case .turnActive = prev, state
    /// == .idle` it replaced — nothing else reaches `.working`, and nothing else
    /// reaches `.settled`.
    var ambientPhase: AmbientPhase {
        switch state {
        case .idle: return .settled
        case .turnActive: return .working
        case .interrupting, .draining: return .stopping
        case .unspawned, .spawning, .failed: return .offstage
        }
    }

    var ambientStatus: SessionStatus { SessionManager.status(of: self) }

    /// What flipped it — the same evidence the status derivation used, as words.
    func troubleReason(_ status: SessionStatus) -> String {
        if status == .error { return lastError ?? "the session is down" }
        if let last = transcript.entries.last, last.role == .notice, last.taskId == nil {
            return last.text   // "session dropped — reconnecting" and kin
        }
        if let r = lastResult, r.isError {
            return r.text ?? "the last turn errored"
        }
        return "needs a look"
    }

    func settledReason(_ status: SessionStatus) -> String {
        if let r = lastResult, !r.deniedTools.isEmpty {
            return "blocked — tools denied: \(r.deniedTools.joined(separator: ", "))"
        }
        return status == .awaitingInput ? "stopped on a question for the owner" : "finished its turn"
    }
}

extension CodexSession: AmbientSession {
    var ambientPhase: AmbientPhase {
        switch state {
        case .idle: return .settled
        case .turnActive: return .working
        case .interrupting: return .stopping
        case .unspawned, .spawning, .failed: return .offstage
        }
    }

    var ambientStatus: SessionStatus { SessionManager.status(of: self) }

    /// codex reports its outcome on the turn rather than in a closing message,
    /// so `lastTurn.error` is the first-hand answer and there is no notice
    /// branch — a resumed thread's history lands under a notice, and claude's
    /// equivalent would read that as a session that just dropped (the same
    /// reason `status(of: CodexSession)` omits it).
    func troubleReason(_ status: SessionStatus) -> String {
        if status == .error { return lastError ?? "the codex session is down" }
        if let error = lastTurn?.error { return error }
        if let error = lastError { return error }
        return "needs a look"
    }

    /// `activeFlags` is app-server's own word for a park — more than claude ever
    /// says about why it stopped — so it is quoted rather than paraphrased.
    func settledReason(_ status: SessionStatus) -> String {
        guard status == .awaitingInput else { return "finished its turn" }
        if !activeFlags.isEmpty {
            return "parked — codex reports \(activeFlags.joined(separator: ", "))"
        }
        return "stopped on a question for the owner"
    }
}
