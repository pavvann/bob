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
        case other(type: String)
    }

    let id: String
    let turnId: String
    let content: Content
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

/// What a `CodexSession` reacts to. Sendable: these cross from the reader,
/// through the coalescer, to the main actor.
enum CodexEvent: Sendable {
    case turnStarted(turnId: String)
    case turnCompleted(turnId: String, status: CodexTurnStatus, durationMs: Int?, error: String?)
    case itemStarted(CodexItem)
    case itemCompleted(CodexItem)
    case agentMessageDelta(itemId: String, text: String)
    case tokenUsage(CodexTokenUsage)
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
        case "thread/tokenUsage/updated":
            guard let usage = tokenUsage(params) else { break }
            return .tokenUsage(usage)
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
        default:
            return CodexItem(id: id, turnId: turnId, content: .other(type: type))
        }
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
