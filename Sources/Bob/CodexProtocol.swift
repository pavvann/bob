import Foundation

// MARK: - ids

/// A JSON-RPC id, string or integer. app-server numbers its own requests out
/// of a space that overlaps bob's — phase 0 watched a server→client request
/// arrive as `id: 0` while bob was numbering from 1 — so an id only means
/// anything alongside the direction it travelled, and bob answers a server
/// request by echoing this value back rather than by minting a number.
enum CodexRequestId: Hashable, Sendable {
    case int(Int)
    case text(String)

    init?(_ value: Any?) {
        switch value {
        case let n as Int: self = .int(n)
        case let s as String: self = .text(s)
        default: return nil
        }
    }

    var json: Any {
        switch self {
        case .int(let n): return n
        case .text(let s): return s
        }
    }
}

// MARK: - wire messages

/// A server→client request, carried whole. Phase 2 must render its buttons
/// from the request's own `availableDecisions`, and that field is on the wire
/// but NOT in 0.149.0's generated schema — a probe watched an exec approval
/// offer `accept` / `acceptWithExecpolicyAmendment` / `cancel`, with no
/// `decline` in sight, from a request the schema describes without the field
/// at all. So any decoded subset is exactly what drops it: `line` is the
/// request verbatim, and phase 2 reads what it needs out of that.
struct CodexServerRequest: Sendable, Identifiable {
    let id: CodexRequestId
    let method: String
    let threadId: String?
    let turnId: String?
    let itemId: String?
    let line: String
}

/// One line off app-server's stdout, classified by SHAPE rather than by id:
/// `id` + `method` is a request coming the other way, `id` alone is a reply to
/// something bob sent, `method` alone is a notification. Responses omit the
/// `jsonrpc` member entirely (codex-cli 0.149.0), so nothing here may require
/// it.
enum CodexWireMessage {
    case response(id: CodexRequestId, result: [String: Any])
    case failure(id: CodexRequestId, code: Int, message: String)
    case request(CodexServerRequest)
    case notification(method: String, params: [String: Any], line: String)
    case undecodable(String)
}

// MARK: - session-facing events

/// One thread item, reduced to what phase 1a renders. Everything else keeps
/// its `type` so a log line and phase 2 both know what went past.
struct CodexItem: Sendable {
    enum Content: Sendable {
        /// `clientId` echoes the `clientUserMessageId` bob sent with the turn —
        /// the only honest way to recognise bob's own prompt coming back.
        case userMessage(text: String, clientId: String?)
        case agentMessage(String)
        /// The one thing claude cannot report: a real command, its live output
        /// and its exit code (#38 T2.3).
        case commandExecution(CodexCommandRun)
        case mcpToolCall(server: String, tool: String, status: CodexWorkStatus)
        case webSearch(query: String)
        case fileChange(changes: [CodexFileEdit], status: CodexWorkStatus)
        /// Both halves arrive empty on `item/started` and populated on
        /// completion; many models never populate either (#38 T2.4).
        case reasoning(summary: [String], content: [String])
        case other(type: String)
    }

    let id: String
    let turnId: String
    let content: Content
}

/// The four item states, one enum. `CommandExecutionStatus` and
/// `PatchApplyStatus` are the same four words and `McpToolCallStatus` is three
/// of them, so nothing is gained by keeping them apart.
enum CodexWorkStatus: String, Sendable, Equatable {
    case inProgress, completed, failed, declined
}

/// A `commandExecution` item. `aggregatedOutput` is reduced to a bounded tail
/// **here**, in the decoder — off the main actor, before the full string can
/// reach anything that retains it.
struct CodexCommandRun: Sendable, Equatable {
    var command: String
    var cwd: String
    var status: CodexWorkStatus
    var exitCode: Int?
    var durationMs: Int?
    var processId: String?
    var output: CodexOutputTail?
}

struct CodexFileEdit: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable, CaseIterable {
        case add, update, delete

        var word: String {
            switch self {
            case .add: return "added"
            case .update: return "edited"
            case .delete: return "deleted"
            }
        }
    }

    var path: String
    var kind: Kind
}

/// What bob keeps of `turn/diff/updated`: three integers.
///
/// The notification carries the whole aggregated unified diff and fires on every
/// file change, so a turn that rewrites a large file pushes megabytes through it.
/// A count is all the gutter shows (a diff view is not in scope), so the tally is
/// computed in the decoder — one pass over the UTF-8 view, no per-line
/// allocation, because splitting a megabyte diff into lines to count them would
/// materialise a substring per line — and the diff itself is dropped on the spot.
struct CodexDiffTally: Sendable, Equatable {
    var files = 0
    var added = 0
    var removed = 0

    var isEmpty: Bool { files == 0 && added == 0 && removed == 0 }

    static func tally(unifiedDiff diff: String) -> CodexDiffTally {
        var files = 0, added = 0, removed = 0
        var column = 0
        var first: UInt8 = 0
        var repeated = 0        // how many leading bytes equal the first one
        func settle() {
            guard column > 0 else { return }
            let tripled = repeated >= 3
            switch first {
            case 0x2B: if tripled { files += 1 } else { added += 1 }     // '+' / '+++'
            case 0x2D: if !tripled { removed += 1 }                      // '-' (and '---' is a header)
            default: break
            }
        }
        for byte in diff.utf8 {
            if byte == 0x0A {
                settle()
                column = 0
                repeated = 0
                continue
            }
            if column == 0 {
                first = byte
                repeated = 1
            } else if repeated == column, byte == first {
                repeated += 1
            }
            column += 1
        }
        settle()
        return CodexDiffTally(files: files, added: added, removed: removed)
    }
}

/// Which coalesced pile a codex fragment belongs to.
///
/// `StreamPump` keys its non-text piles by an opaque string — it is generic over
/// providers and has no business learning codex's item vocabulary — so this is
/// how that key is spelled, in one place, with the item id last so the split can
/// never be ambiguous.
enum CodexStreamTarget: Sendable, Equatable {
    case commandOutput(item: String)
    case reasoningSummary(item: String, part: Int)
    case reasoningText(item: String)

    var key: String {
        switch self {
        case .commandOutput(let item): return "cmd:\(item)"
        case .reasoningSummary(let item, let part): return "rsum:\(part):\(item)"
        case .reasoningText(let item): return "rtext:\(item)"
        }
    }

    init?(key: String) {
        if key.hasPrefix("cmd:") {
            self = .commandOutput(item: String(key.dropFirst(4)))
        } else if key.hasPrefix("rtext:") {
            self = .reasoningText(item: String(key.dropFirst(6)))
        } else if key.hasPrefix("rsum:") {
            let rest = key.dropFirst(5)
            guard let split = rest.firstIndex(of: ":"),
                  let part = Int(rest[rest.startIndex..<split])
            else { return nil }
            self = .reasoningSummary(item: String(rest[rest.index(after: split)...]), part: part)
        } else {
            return nil
        }
    }
}

/// `thread/tokenUsage/updated`. `modelContextWindow` is the whole reason the
/// context meter needs no per-model table on this side (#35).
struct CodexTokenUsage: Sendable {
    var turnId = ""
    var inputTokens = 0
    var cachedInputTokens = 0
    var cacheWriteInputTokens = 0
    var outputTokens = 0
    /// `total.totalTokens` — the conversation's running spend, not its window.
    var sessionTotalTokens = 0
    var modelContextWindow: Int?

    /// What the model had in front of it on the last request. `inputTokens` is
    /// the whole prompt and `cachedInputTokens` is the share of it that was
    /// cached, so unlike claude's counts the cached half must NOT be added
    /// again — a probe's first turn read 18,904 input of which 11,008 cached,
    /// against a 258,400 window.
    var contextInUse: Int { inputTokens }
}

/// `account/rateLimits/updated`, and the same `RateLimitSnapshot` that
/// `account/rateLimits/read` answers under the same key — one shape, two
/// arrivals. Pushed unasked, once a turn: no endpoint, no keychain, no poll.
///
/// **Every field is optional because the notification is explicitly sparse.**
/// The schema says a rolling update carries what moved, and that a nullable
/// field being absent "does not clear a previously observed value" — so this
/// decodes to absences and the meter merges. Nothing here may be read as "the
/// account no longer has one of these".
///
/// Carries no freshness timestamp, deliberately (#26): a `Date()` in a published
/// value makes every snapshot compare unequal, and then an equality guard
/// invalidates the window on every push that changed nothing.
struct CodexRateLimits: Sendable, Equatable {
    /// One rolling window. `usedPercent` is the only required member, so a
    /// window that decodes at all is a window worth drawing.
    struct Window: Sendable, Equatable {
        var usedPercent: Double
        var resetsAt: Date?
        /// 300 and 10080 live — five hours and a week. Kept rather than assumed,
        /// because it is what decides which of the two a window *is*.
        var windowMins: Int?
    }

    var primary: Window?
    var secondary: Window?

    /// A rolling update carries what moved; an absence is silence, not a
    /// retraction. A present window is always complete (`usedPercent` is
    /// required inside one), so this merges whole windows rather than fields.
    mutating func merge(_ update: CodexRateLimits) {
        if let primary = update.primary { self.primary = primary }
        if let secondary = update.secondary { self.secondary = secondary }
    }

    var isEmpty: Bool { primary == nil && secondary == nil }
}

/// What a `CodexSession` reacts to. Sendable: these cross from the reader,
/// through the coalescer, to the main actor.
enum CodexEvent: Sendable {
    case turnStarted(turnId: String)
    case turnCompleted(turnId: String, status: CodexTurnStatus, durationMs: Int?, error: String?)
    case itemStarted(CodexItem)
    case itemCompleted(CodexItem)
    case agentMessageDelta(itemId: String, text: String)
    /// `item/commandExecution/outputDelta` — a firehose with no ceiling, so it
    /// rides the coalescer keyed by item and is retained only as a tail.
    ///
    /// There is no sibling for file changes: `item/fileChange/outputDelta` is
    /// deprecated and 0.149.0's own schema says the server no longer emits it,
    /// so nothing here waits on one.
    case commandOutputDelta(itemId: String, chunk: String)
    case reasoningDelta(itemId: String, text: String, lane: CodexReasoningLane)
    /// `item/reasoning/summaryPartAdded` — a paragraph break, not content.
    case reasoningPartAdded(itemId: String, part: Int)
    case turnDiff(turnId: String, tally: CodexDiffTally)
    case tokenUsage(CodexTokenUsage)
    /// `account/rateLimits/updated` — the account's, not a thread's, so no
    /// session owns it: it reaches `CodexServer.events` and the statusline strip
    /// is its only subscriber (#38 T2.5).
    case rateLimits(CodexRateLimits)
    case threadStatus(kind: String, activeFlags: [String])
    /// `error` — a turn failed. `willRetry` means app-server is having another
    /// go on its own and no `turn/completed` follows yet.
    case turnFailed(message: String, willRetry: Bool)
    /// The process itself is gone. Distinct from `turnFailed` because that one
    /// is survivable — the thread lives and the next turn works — and this one
    /// takes every turn, every pending answer and the thread's route with it.
    case serverExited(String)
    case serverRequest(CodexServerRequest)
    /// `serverRequest/resolved` — this request has an answer, possibly not
    /// bob's: another client attached to the same thread can settle one. The
    /// card has to come down either way, or it offers to answer something
    /// nobody is asking any more.
    case requestResolved(CodexRequestId)
    /// Decoded fine, not modelled here. Forward-compatible on purpose: a new
    /// method must be able to say less, never to break the stream.
    case unmodeled(method: String, line: String)
}

enum CodexTurnStatus: String, Sendable {
    case completed, interrupted, failed, inProgress
}

/// Which half of a reasoning item a delta belongs to. The summary is the thing
/// worth reading; raw `textDelta` is model-dependent — most emit none — so it is
/// optional detail behind it, never the row's content.
enum CodexReasoningLane: Sendable, Equatable {
    case summary(part: Int)
    case raw
}

// MARK: - outbound policy

/// `sandboxPolicy` is a tagged union on `type`; phase 0 got
/// `missing field 'type'` back for `{"mode": …}`. `dangerFullAccess` and
/// `externalSandbox` are deliberately absent — bob has no reason to hand codex
/// the whole machine, and a case that doesn't exist can't be sent by accident.
enum CodexSandboxPolicy: Sendable, Equatable {
    case readOnly
    case workspaceWrite(writableRoots: [String])

    var json: [String: Any] {
        switch self {
        case .readOnly:
            return ["type": "readOnly"]
        case .workspaceWrite(let roots):
            return ["type": "workspaceWrite", "writableRoots": roots]
        }
    }
}

enum CodexApprovalPolicy: String, Sendable {
    case untrusted
    case onRequest = "on-request"
    case never
}

// MARK: - decoding

/// Every reader here tolerates a missing field and an unknown shape becomes
/// `.unmodeled` — the stream must never be able to crash bob, only to say
/// less. Shapes checked against `codex app-server generate-json-schema` for
/// codex-cli 0.149.0.
enum CodexJSON {
    static func decode(_ line: String) -> CodexWireMessage {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .undecodable(line) }

        let params = obj["params"] as? [String: Any] ?? [:]
        switch (CodexRequestId(obj["id"]), obj["method"] as? String) {
        case (let id?, let method?):
            return .request(CodexServerRequest(
                id: id,
                method: method,
                threadId: params["threadId"] as? String,
                turnId: params["turnId"] as? String,
                itemId: params["itemId"] as? String,
                line: line
            ))
        case (let id?, nil):
            if let error = obj["error"] as? [String: Any] {
                return .failure(
                    id: id,
                    code: (error["code"] as? Int) ?? 0,
                    message: (error["message"] as? String) ?? "codex refused the request"
                )
            }
            return .response(id: id, result: obj["result"] as? [String: Any] ?? [:])
        case (nil, let method?):
            return .notification(method: method, params: params, line: line)
        case (nil, nil):
            return .undecodable(line)
        }
    }

    /// Which session a notification belongs to. `thread/started` names its
    /// thread one level down, inside the Thread it carries.
    static func threadId(of params: [String: Any]) -> String? {
        params["threadId"] as? String
            ?? (params["thread"] as? [String: Any])?["id"] as? String
    }

    static func event(method: String, params: [String: Any], line: String) -> CodexEvent {
        switch method {
        case "turn/started":
            guard let id = turn(params)?["id"] as? String else { break }
            return .turnStarted(turnId: id)
        case "turn/completed":
            guard let turn = turn(params), let id = turn["id"] as? String else { break }
            let status = CodexTurnStatus(rawValue: (turn["status"] as? String) ?? "") ?? .completed
            return .turnCompleted(
                turnId: id,
                status: status,
                durationMs: turn["durationMs"] as? Int,
                error: (turn["error"] as? [String: Any])?["message"] as? String
            )
        case "item/started":
            guard let item = item(params) else { break }
            return .itemStarted(item)
        case "item/completed":
            guard let item = item(params) else { break }
            return .itemCompleted(item)
        case "item/agentMessage/delta":
            guard let itemId = params["itemId"] as? String,
                  let text = params["delta"] as? String
            else { break }
            return .agentMessageDelta(itemId: itemId, text: text)
        case "item/commandExecution/outputDelta":
            guard let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String
            else { break }
            return .commandOutputDelta(itemId: itemId, chunk: delta)
        case "item/reasoning/summaryTextDelta":
            guard let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String
            else { break }
            return .reasoningDelta(itemId: itemId, text: delta,
                                   lane: .summary(part: (params["summaryIndex"] as? Int) ?? 0))
        case "item/reasoning/textDelta":
            guard let itemId = params["itemId"] as? String,
                  let delta = params["delta"] as? String
            else { break }
            return .reasoningDelta(itemId: itemId, text: delta, lane: .raw)
        case "item/reasoning/summaryPartAdded":
            guard let itemId = params["itemId"] as? String else { break }
            return .reasoningPartAdded(itemId: itemId,
                                       part: (params["summaryIndex"] as? Int) ?? 0)
        case "turn/diff/updated":
            guard let turnId = params["turnId"] as? String,
                  let diff = params["diff"] as? String
            else { break }
            // counted here and thrown away here — see CodexDiffTally
            return .turnDiff(turnId: turnId, tally: .tally(unifiedDiff: diff))
        case "thread/tokenUsage/updated":
            guard let usage = tokenUsage(params) else { break }
            return .tokenUsage(usage)
        case "account/rateLimits/updated":
            guard let snapshot = params["rateLimits"] as? [String: Any] else { break }
            let limits = rateLimits(snapshot)
            // an update that named neither window says nothing bob draws; let it
            // stay opaque rather than publish an empty snapshot over a good one
            guard !limits.isEmpty else { break }
            return .rateLimits(limits)
        case "thread/status/changed":
            guard let status = params["status"] as? [String: Any] else { break }
            return .threadStatus(
                kind: (status["type"] as? String) ?? "?",
                activeFlags: (status["activeFlags"] as? [String]) ?? []
            )
        case "serverRequest/resolved":
            guard let id = CodexRequestId(params["requestId"]) else { break }
            return .requestResolved(id)
        case "error":
            guard let error = params["error"] as? [String: Any] else { break }
            return .turnFailed(
                message: (error["message"] as? String) ?? "codex reported an error",
                willRetry: (params["willRetry"] as? Bool) ?? false
            )
        default:
            break
        }
        return .unmodeled(method: method, line: line)
    }

    private static func turn(_ params: [String: Any]) -> [String: Any]? {
        params["turn"] as? [String: Any]
    }

    private static func item(_ params: [String: Any]) -> CodexItem? {
        guard let obj = params["item"] as? [String: Any] else { return nil }
        return item(obj, turnId: (params["turnId"] as? String) ?? "")
    }

    /// The turns `thread/resume` hands back inside its Thread — the only
    /// response that carries them populated. Nothing replays them as
    /// notifications, so this is where a resumed conversation's history comes
    /// from or it doesn't come at all. Flattened in order: a transcript is one
    /// column, and the turn boundaries are already visible in who is speaking.
    static func history(of thread: [String: Any]) -> [CodexItem] {
        (thread["turns"] as? [[String: Any]] ?? []).flatMap { turn -> [CodexItem] in
            let turnId = (turn["id"] as? String) ?? ""
            return (turn["items"] as? [[String: Any]] ?? []).compactMap {
                item($0, turnId: turnId)
            }
        }
    }

    static func item(_ obj: [String: Any], turnId: String) -> CodexItem? {
        guard let id = obj["id"] as? String,
              let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "userMessage":
            let text = ((obj["content"] as? [[String: Any]]) ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            return CodexItem(id: id, turnId: turnId,
                             content: .userMessage(text: text, clientId: obj["clientId"] as? String))
        case "agentMessage":
            return CodexItem(id: id, turnId: turnId,
                             content: .agentMessage((obj["text"] as? String) ?? ""))
        case "commandExecution":
            let run = CodexCommandRun(
                command: (obj["command"] as? String) ?? "",
                cwd: (obj["cwd"] as? String) ?? "",
                status: status(obj["status"]),
                exitCode: obj["exitCode"] as? Int,
                durationMs: obj["durationMs"] as? Int,
                processId: obj["processId"] as? String,
                // the tail is taken now, off the main actor, and the full
                // aggregate is released with this dictionary
                output: (obj["aggregatedOutput"] as? String).map(CodexOutputTail.tail(of:))
            )
            return CodexItem(id: id, turnId: turnId, content: .commandExecution(run))
        case "mcpToolCall":
            return CodexItem(id: id, turnId: turnId, content: .mcpToolCall(
                server: (obj["server"] as? String) ?? "?",
                tool: (obj["tool"] as? String) ?? "?",
                status: status(obj["status"])))
        case "webSearch":
            return CodexItem(id: id, turnId: turnId,
                             content: .webSearch(query: (obj["query"] as? String) ?? ""))
        case "fileChange":
            let changes = (obj["changes"] as? [[String: Any]] ?? []).compactMap { change -> CodexFileEdit? in
                guard let path = change["path"] as? String else { return nil }
                // `kind` is a tagged union, not a bare string — an unnamed one
                // is still a change, so it reads as an edit rather than vanishing
                let raw = (change["kind"] as? [String: Any])?["type"] as? String
                return CodexFileEdit(path: path, kind: CodexFileEdit.Kind(rawValue: raw ?? "") ?? .update)
            }
            return CodexItem(id: id, turnId: turnId,
                             content: .fileChange(changes: changes, status: status(obj["status"])))
        case "reasoning":
            return CodexItem(id: id, turnId: turnId, content: .reasoning(
                summary: (obj["summary"] as? [String]) ?? [],
                content: (obj["content"] as? [String]) ?? []))
        default:
            return CodexItem(id: id, turnId: turnId, content: .other(type: type))
        }
    }

    /// An unknown or absent status reads as still running: a row that claims to
    /// have finished when nothing said so is the one wrong answer here.
    private static func status(_ raw: Any?) -> CodexWorkStatus {
        CodexWorkStatus(rawValue: (raw as? String) ?? "") ?? .inProgress
    }

    /// A `RateLimitSnapshot`, from either the push or the one-shot read. Only
    /// the two windows are decoded: `planType`, `credits`, `limitName` and
    /// `spendControlReached` all arrive and none of them is drawn, and a field
    /// bob doesn't draw is a field that can't break it (UsageMeter's own rule).
    /// `rateLimitReachedType` is the one omission worth naming — the sparse
    /// merge cannot tell "no longer reached" from "not mentioned", so a word
    /// held from it would outlive the fact; 100% already goes red on its own.
    static func rateLimits(_ snapshot: [String: Any]) -> CodexRateLimits {
        CodexRateLimits(primary: window(snapshot["primary"]),
                        secondary: window(snapshot["secondary"]))
    }

    /// `usedPercent` arrives as an int32 and `resetsAt` as unix **seconds** —
    /// both read live (51% / 300 mins / 1787943426 → an instant two hours out).
    /// Numbers are taken through `NSNumber` because JSONSerialization is free to
    /// hand back either an Int or a Double for the same field.
    private static func window(_ any: Any?) -> CodexRateLimits.Window? {
        guard let obj = any as? [String: Any],
              let used = (obj["usedPercent"] as? NSNumber)?.doubleValue
        else { return nil }
        return CodexRateLimits.Window(
            usedPercent: min(100, max(0, used)),
            resetsAt: (obj["resetsAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) },
            windowMins: (obj["windowDurationMins"] as? NSNumber)?.intValue
        )
    }

    private static func tokenUsage(_ params: [String: Any]) -> CodexTokenUsage? {
        guard let usage = params["tokenUsage"] as? [String: Any] else { return nil }
        let last = usage["last"] as? [String: Any] ?? [:]
        var t = CodexTokenUsage()
        t.turnId = (params["turnId"] as? String) ?? ""
        t.inputTokens = (last["inputTokens"] as? Int) ?? 0
        t.cachedInputTokens = (last["cachedInputTokens"] as? Int) ?? 0
        t.cacheWriteInputTokens = (last["cacheWriteInputTokens"] as? Int) ?? 0
        t.outputTokens = (last["outputTokens"] as? Int) ?? 0
        t.sessionTotalTokens = ((usage["total"] as? [String: Any])?["totalTokens"] as? Int) ?? 0
        t.modelContextWindow = usage["modelContextWindow"] as? Int
        return t
    }
}
