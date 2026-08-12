import Combine
import Foundation

// MARK: - the ask

/// A permission update the CLI itself offered alongside a can_use_tool ask
/// (`permission_suggestions`, probe 1.6) — in practice
/// `{"type":"setMode","mode":"acceptEdits","destination":"session"}`. Handing one
/// back with an allow is what makes "always" mean something to the CLI and not
/// only to bob. Fields ride along verbatim so a suggestion shape nobody has seen
/// yet still round-trips instead of being flattened into what we understood.
struct PermissionSuggestion {
    let fields: [String: Any]

    var type: String? { fields["type"] as? String }
    var mode: String? { fields["mode"] as? String }
    var destination: String? { fields["destination"] as? String }
}

/// One tool call waiting on the owner. The CLI is blocked on it: manual mode +
/// `--permission-prompt-tool stdio` turns every tool into this question, and the
/// turn does not move until a control_response goes back (probe 1.6).
struct PermissionRequest: Identifiable {
    /// The CLI's own request_id — the reply must echo it exactly.
    let requestId: String
    let sessionId: UUID
    let sessionName: String
    let toolName: String
    /// The tool's arguments verbatim, echoed back as `updatedInput` on allow.
    /// nil when the ask carried none — better no field than an empty one.
    let input: [String: Any]?
    /// The one line the owner actually decides on: the argument that matters,
    /// paths in full (home-abbreviated). "notes.txt" is not enough to approve a
    /// write — *which* notes.txt is the whole question.
    let detail: String
    /// SF Symbol from the shared tool vocabulary, so a Write here and a Write in
    /// a panel feed wear the same glyph.
    let symbol: String
    let suggestions: [PermissionSuggestion]
    let asked = Date()

    /// Per-session, because the continuation waiting on this is keyed by it and
    /// two CLIs are two id spaces.
    var id: String { "\(sessionId.uuidString)/\(requestId)" }

    /// What "always" would actually mean, in words, for the tooltip.
    var alwaysScope: String { "allow \(toolName) for the rest of this session" }

    /// Decoded straight off the raw control_request line — StreamJSON hands the
    /// line through untouched precisely so the parts nobody else needs (input,
    /// suggestions) can be read here instead of widening the event enum.
    init(requestId: String, sessionId: UUID, sessionName: String,
         toolName: String, rawJSON: String) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.toolName = toolName

        let request = Self.requestObject(rawJSON)
        let input = request["input"] as? [String: Any]
        self.input = input
        self.suggestions = ((request["permission_suggestions"] as? [[String: Any]]) ?? [])
            .map(PermissionSuggestion.init)

        let humanized = Self.humanized(tool: toolName, input: input ?? [:])
        self.symbol = humanized?.symbol ?? "shield.lefthalf.filled"
        self.detail = Self.detail(input: input)
            ?? (request["description"] as? String)
            ?? humanized?.text
            ?? toolName.lowercased()
    }

    /// Test/harness door — a request with everything already decided.
    init(requestId: String, sessionId: UUID, sessionName: String, toolName: String,
         input: [String: Any]?, detail: String, symbol: String = "shield.lefthalf.filled",
         suggestions: [PermissionSuggestion] = []) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.toolName = toolName
        self.input = input
        self.detail = detail
        self.symbol = symbol
        self.suggestions = suggestions
    }

    private static func requestObject(_ line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let request = obj["request"] as? [String: Any]
        else { return [:] }
        return request
    }

    /// The argument worth reading, in priority order — one line, whole path.
    private static let argumentKeys = [
        "file_path", "notebook_path", "path", "command", "pattern",
        "url", "query", "skill", "subagent_type", "description", "prompt",
    ]

    private static func detail(input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in argumentKeys {
            guard let raw = input[key] as? String, !raw.isEmpty else { continue }
            let line = raw.split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map(String.init) ?? raw
            let text = key.hasSuffix("path") ? abbreviate(line) : line
            return String(text.trimmingCharacters(in: .whitespaces).prefix(240))
        }
        return nil
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Borrows the shared tool vocabulary (glyph + phrasing) through the same
    /// front door StreamJSON uses, so nothing here invents a second dialect.
    private static func humanized(tool: String, input: [String: Any]) -> FeedEvent? {
        var update = TranscriptParser.Update()
        let synthetic: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "name": tool, "input": input]]],
        ]
        TranscriptParser.ingest(synthetic, flavor: .minionStream, into: &update)
        return update.events.first
    }
}

// MARK: - the broker

/// Ask-first's other half: the CLI's questions come in here, the owner's answers
/// go back out. `decide` suspends the routing task until a button is pressed —
/// the claude on the other end is blocked the whole time, which is the point:
/// nothing runs in a project until someone said yes.
///
/// A singleton because the approval cards are drawn in two places at once (the
/// tab strip and any floating panel watching that session) and both must show
/// the same one card, not two copies of a decision.
@MainActor
final class UIPermissionBroker: ObservableObject, PermissionBroker {
    static let shared = UIPermissionBroker()

    /// Every open ask, oldest first, across every session.
    @Published private(set) var pending: [PermissionRequest] = []

    private var waiters: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
    /// Tools the owner blessed for the rest of a session — the client-side half
    /// of "always allow". The CLI is *also* told (via its own suggestion), but
    /// this half needs no cooperation from the wire to work.
    private var blanket: [UUID: Set<String>] = [:]

    /// What a denied tool tells the model. Written as an instruction, not a
    /// scolding: the point is that it stops retrying and says something instead.
    nonisolated static let refusal = "the owner denied this tool call. don't retry it — "
                                  + "say what you needed and why, in one line."

    // MARK: what the views read

    func asks(for sessionId: UUID) -> [PermissionRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    func ask(for sessionId: UUID) -> PermissionRequest? {
        pending.first { $0.sessionId == sessionId }
    }

    func count(for sessionId: UUID) -> Int {
        pending.reduce(0) { $0 + ($1.sessionId == sessionId ? 1 : 0) }
    }

    /// Tools already blessed in this session, for the card's "always on" hint.
    func blessed(in sessionId: UUID) -> Set<String> { blanket[sessionId] ?? [] }

    // MARK: PermissionBroker

    func decide(_ request: PermissionRequest) async -> PermissionDecision {
        if blanket[request.sessionId]?.contains(request.toolName) == true {
            return .allow          // the owner already said "always" for this tool
        }
        return await withCheckedContinuation { continuation in
            pending.append(request)
            waiters[request.id] = continuation
        }
    }

    /// The process died or was closed — no one is listening for the answer, so
    /// resolve every open ask (deny: the safe read of silence) and clear the
    /// cards. The session's blanket goes with it; a new process starts honest.
    func abandon(sessionId: UUID) {
        for request in pending where request.sessionId == sessionId {
            waiters.removeValue(forKey: request.id)?
                .resume(returning: .deny(message: "the session went away"))
        }
        pending.removeAll { $0.sessionId == sessionId }
        blanket[sessionId] = nil
    }

    // MARK: the buttons

    func allow(_ request: PermissionRequest) {
        settle(request, .allow)
    }

    /// "always" — bob stops asking (blanket), and the CLI is invited to stop too
    /// by handing its own suggestion straight back. If it ignores the suggestion
    /// the asks keep coming and the blanket answers them silently; either way the
    /// owner isn't asked twice.
    func allowAlways(_ request: PermissionRequest) {
        blanket[request.sessionId, default: []].insert(request.toolName)
        settle(request, request.suggestions.isEmpty ? .allow : .allowAdopting(request.suggestions))
    }

    func deny(_ request: PermissionRequest, message: String = UIPermissionBroker.refusal) {
        settle(request, .deny(message: message))
    }

    /// One answer per ask: a second click (card in the tab *and* in a panel)
    /// finds no continuation and does nothing.
    private func settle(_ request: PermissionRequest, _ decision: PermissionDecision) {
        guard let continuation = waiters.removeValue(forKey: request.id) else { return }
        pending.removeAll { $0.id == request.id }
        continuation.resume(returning: decision)
    }
}
