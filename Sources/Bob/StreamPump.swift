import Foundation

/// Sits between the decode loop and the main actor (plan D2, P2a). Text
/// deltas pile up here and cross as ONE main-actor mutation per ~16ms
/// window; ordering-sensitive events flush the pile first, then cross
/// immediately behind it. The first pending fragment arms the deadline and
/// later fragments never extend it, so a continuous stream cannot starve
/// the flush — and chatter nobody renders dies here, off-main.
///
/// Generic over the event type because codex streams through exactly the same
/// discipline (#37). The provider supplies the lane classifier and the one
/// doorway onto the main actor; only the *timing* lives here, so the
/// generation/deadline dance exists once rather than once per provider.
actor StreamPump<Event: Sendable> {
    enum Lane {
        case coalesce(String)   // text delta — accumulate for the window
        case nudge              // thinking chatter — one idle check per window
        case drop               // non-visual; nothing downstream needs it
        case boundary           // ordering-sensitive — flush text, then deliver
    }

    private let classify: @Sendable (Event) -> Lane
    private let deliver: @Sendable (String?, Event?) async -> Void
    private var pending: [String] = []
    /// Thinking chatter wants a spontaneous-turn check — delivered at most
    /// once per boundary window, so a long think costs one hop, not sixty.
    private var nudgePending = false
    private var nudgeDelivered = false
    private var deadline: Task<Void, Never>?
    /// Bumped by every boundary. A deadline that wakes into a stale
    /// generation knows a boundary already owns its batch — no double flush.
    private var generation = 0

    init(classify: @escaping @Sendable (Event) -> Lane,
         deliver: @escaping @Sendable (String?, Event?) async -> Void) {
        self.classify = classify
        self.deliver = deliver
    }

    func ingest(_ event: Event) async {
        switch classify(event) {
        case .drop:
            return
        case .coalesce(let text):
            pending.append(text)
            armIfNeeded()
        case .nudge:
            guard !nudgeDelivered else { return }
            nudgePending = true
            armIfNeeded()
        case .boundary:
            generation += 1
            if let d = deadline { d.cancel(); await d.value; deadline = nil }
            await send(boundary: event)
            nudgeDelivered = false   // a fresh turn may follow — let it nudge once
        }
    }

    /// The stream is over — push whatever is still pending before the exit
    /// handler runs, so the last fragment of a dying turn is never lost.
    func finish() async {
        generation += 1
        if let d = deadline { d.cancel(); await d.value; deadline = nil }
        if !pending.isEmpty { await send(boundary: nil) }
    }

    private func armIfNeeded() {
        guard deadline == nil else { return }   // one window; fragments never extend it
        let gen = generation
        deadline = Task { [weak self] in
            let clock = ContinuousClock()
            try? await clock.sleep(until: clock.now + .milliseconds(16))
            await self?.fire(ifStill: gen)
        }
    }

    private func fire(ifStill gen: Int) async {
        guard gen == generation else { return }   // a boundary took this batch
        await send(boundary: nil)
        guard gen == generation else { return }   // a boundary crossed mid-flush and owns `deadline`
        deadline = nil
        // fragments that landed while the flush was crossing get a new window
        if !pending.isEmpty || nudgePending { armIfNeeded() }
    }

    private func send(boundary: Event?) async {
        let text = pending.isEmpty ? nil : pending.joined()
        pending.removeAll(keepingCapacity: true)
        if nudgePending { nudgePending = false; nudgeDelivered = true }
        await deliver(text, boundary)
    }
}

// MARK: - claude

extension StreamPump where Event == StreamEvent {
    static func claude(session: ClaudeSession) -> StreamPump<StreamEvent> {
        StreamPump(classify: { Self.lane(for: $0) }, deliver: { [weak session] text, boundary in
            await session?.applyPump(text: text, boundary: boundary)
        })
    }

    /// Classification runs before any actor is crossed. Everything the state
    /// machine acts on is a boundary; the rest is either the firehose (text)
    /// or noise (message_start/stop, signature deltas).
    static func lane(for event: StreamEvent) -> Lane {
        switch event {
        case .streamEvent(.textDelta(let text)):
            return text.isEmpty ? .drop : .coalesce(text)
        case .streamEvent(.thinkingDelta):
            return .nudge
        case .streamEvent(.other):
            return .drop
        case .ignored:
            return .drop            // the reader already logged the forensics
        case .rateLimit:
            // session metadata, and rare: the CLI emits one per turn at most, so
            // it rides the boundary lane like every other state event. Spelled
            // out rather than left to `default` because the one thing it must
            // never become is a per-token hop — that lane is `coalesce`, above,
            // and nothing else may join it.
            return .boundary
        default:
            return .boundary
        }
    }
}
