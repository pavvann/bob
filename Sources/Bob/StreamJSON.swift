import Foundation

// MARK: - line framing

/// Turns raw pipe reads into complete newline-terminated lines. Pipe reads
/// break at arbitrary byte offsets — mid-line, mid-codepoint — so bytes
/// accumulate here and only whole lines come out; the partial tail waits for
/// the next read. UTF-8 boundary safety falls out for free: a whole line is
/// always codepoint-complete. Consumption is a read cursor and ONE compaction
/// per consume() — never a front-removal per line, which went quadratic on a
/// bursty chunk. A defensive cap drops any line past 4MB (init lines run
/// ~10KB; megabytes mean something upstream broke) whether it arrives in
/// pieces or already newline-complete — callers watch `droppedLines` and log.
struct LineFramer {
    static let maxLineBytes = 4 * 1024 * 1024

    private var buffer = Data()
    /// Bytes already searched for a newline — a line arriving in many chunks
    /// is still scanned once.
    private var scanned = 0
    private var discardingOversized = false
    private(set) var droppedLines = 0

    mutating func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        var lineStart = buffer.startIndex
        var searchFrom = buffer.index(buffer.startIndex, offsetBy: scanned)
        while let newline = buffer[searchFrom...].firstIndex(of: 0x0A) {
            let raw = buffer.subdata(in: lineStart..<newline)
            searchFrom = buffer.index(after: newline)
            lineStart = searchFrom
            if discardingOversized {
                // the tail of a line whose head was already dropped
                discardingOversized = false
                droppedLines += 1
                continue
            }
            if raw.count > Self.maxLineBytes {
                // oversized but complete in one buffer — the cap still holds
                droppedLines += 1
                continue
            }
            guard !raw.isEmpty, var line = String(data: raw, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        if discardingOversized {
            // still inside the oversized line — everything buffered is part of it
            buffer.removeAll(keepingCapacity: false)
        } else if buffer.count > Self.maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
            discardingOversized = true
        }
        scanned = buffer.count
        return lines
    }
}

// MARK: - typed events

/// One line of `claude -p --output-format stream-json`, decoded defensively.
/// Shapes verified against CLI 2.1.227 (session plan part 1). Every decoder
/// tolerates missing fields; unknown shapes become `.ignored` — the stream
/// must never be able to crash bob, only to say less.
enum StreamEvent: Equatable, Sendable {
    /// `system/init` — re-emitted at the start of EVERY turn, not just the first.
    case initialized(sessionId: String, model: String?)
    /// `system/status` — the CLI began working a turn ("requesting").
    case status(String?)
    /// partial-message events (only with `--include-partial-messages`).
    case streamEvent(Partial)
    /// `assistant` — emitted once per completed content block. `usage` is the
    /// token count that message ran with; the last one of a turn is what the
    /// model had in front of it when the turn ended.
    case assistant([AssistantBlock], usage: TokenUsage?)
    /// `user` carrying tool_result blocks — a tool finished.
    case toolResult(isError: Bool)
    case taskStarted(id: String, description: String?, subagentType: String?, taskType: String?)
    case taskUpdated(id: String, status: String?)
    /// the between-turn doorbell (probe 1.2): a background task finished and
    /// a spontaneous model turn follows with no stdin input.
    case taskNotification(id: String, status: String, summary: String?)
    case backgroundTasksChanged(count: Int)
    case permissionDenied(tool: String, message: String?)
    case result(TurnResult)
    /// CLI → bob (can_use_tool in ask-first mode). Raw line kept for the broker.
    /// `requiresUserInteraction` is the CLI's own flag for a tool that can only
    /// be answered by a person — AskUserQuestion. It arrives on the same
    /// can_use_tool channel as a permission ask, but it's a question, not a
    /// permission, and bob shows it as one (probe 2026-08-13).
    case controlRequest(id: String, subtype: String, toolName: String?,
                        requiresUserInteraction: Bool, rawJSON: String)
    /// ack for a control_request bob sent (interrupt).
    case controlResponse(id: String?, ok: Bool)
    /// `rate_limit_event` — the CLI's own read on the subscription block.
    /// Session metadata, not transcript: it says nothing about the conversation
    /// and only ever moves the global meter.
    case rateLimit(type: String?, resetsAt: Date?, isUsingOverage: Bool)
    /// hooks, thinking meters, unknown shapes. `forensic` is non-nil only when
    /// the line didn't decode at all — callers log those.
    case ignored(forensic: String?)

    enum Partial: Equatable, Sendable {
        case textDelta(String)
        case thinkingDelta
        case blockStart(kind: String)   // "text" | "thinking" | "tool_use"
        case blockStop
        case messageDelta(stopReason: String?)
        case other                      // message_start/stop, signature deltas
    }

    enum AssistantBlock: Equatable, Sendable {
        case text(String)
        case thinking
        /// `activity` is the humanized line ("reading Foo.swift") for the
        /// live-activity row, built by TranscriptParser's shared vocabulary.
        case toolUse(name: String, activity: String)
    }
}

/// The token counts riding one assistant message. `contextInUse` is what the
/// model actually had in front of it — fresh input plus both halves of the
/// cache, because a cached token occupies the window exactly as much as a new
/// one does. Output stays out: it's what the model wrote, not what it read.
struct TokenUsage: Equatable, Sendable {
    var inputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var outputTokens = 0

    var contextInUse: Int { inputTokens + cacheReadTokens + cacheCreationTokens }
}

/// The closing record of a turn (`type: result`).
struct TurnResult: Equatable, Sendable {
    var subtype: String?
    var isError = false
    var text: String?
    var terminalReason: String?
    var stopReason: String?
    var numTurns: Int?
    var durationMs: Int?
    var costUSD: Double?
    var deniedTools: [String] = []
}

// MARK: - decoding

enum StreamJSON {
    static func decode(_ line: String) -> StreamEvent {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String
        else { return .ignored(forensic: line) }

        switch type {
        case "system":
            return system(obj)
        case "stream_event":
            return partial(obj)
        case "assistant":
            return assistant(obj)
        case "user":
            return user(obj)
        case "result":
            return result(obj)
        case "control_request":
            let request = obj["request"] as? [String: Any]
            return .controlRequest(
                id: (obj["request_id"] as? String) ?? "",
                subtype: (request?["subtype"] as? String) ?? "?",
                toolName: request?["tool_name"] as? String,
                requiresUserInteraction: (request?["requires_user_interaction"] as? Bool) ?? false,
                rawJSON: line
            )
        case "control_response":
            let response = obj["response"] as? [String: Any]
            return .controlResponse(
                id: response?["request_id"] as? String,
                ok: (response?["subtype"] as? String) == "success"
            )
        case "rate_limit_event":
            return rateLimit(obj)
        default:
            // a shape the probes never saw — keep the evidence (risk #2)
            return .ignored(forensic: line)
        }
    }

    private static func system(_ obj: [String: Any]) -> StreamEvent {
        switch obj["subtype"] as? String {
        case "init":
            return .initialized(
                sessionId: (obj["session_id"] as? String) ?? "",
                model: obj["model"] as? String
            )
        case "status":
            return .status(obj["status"] as? String)
        case "task_started":
            return .taskStarted(
                id: (obj["task_id"] as? String) ?? "",
                description: obj["description"] as? String,
                subagentType: obj["subagent_type"] as? String,
                taskType: obj["task_type"] as? String
            )
        case "task_updated":
            return .taskUpdated(
                id: (obj["task_id"] as? String) ?? "",
                status: (obj["patch"] as? [String: Any])?["status"] as? String
            )
        case "task_notification":
            return .taskNotification(
                id: (obj["task_id"] as? String) ?? "",
                status: (obj["status"] as? String) ?? "?",
                summary: obj["summary"] as? String
            )
        case "background_tasks_changed":
            return .backgroundTasksChanged(count: ((obj["tasks"] as? [Any]) ?? []).count)
        case "permission_denied":
            return .permissionDenied(
                tool: (obj["tool_name"] as? String) ?? "?",
                message: obj["message"] as? String
            )
        default:
            // hooks, thinking_tokens meters, future system chatter (edge 8)
            return .ignored(forensic: nil)
        }
    }

    private static func partial(_ obj: [String: Any]) -> StreamEvent {
        guard let event = obj["event"] as? [String: Any],
              let kind = event["type"] as? String
        else { return .ignored(forensic: nil) }
        switch kind {
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                return .streamEvent(.textDelta((delta?["text"] as? String) ?? ""))
            case "thinking_delta":
                return .streamEvent(.thinkingDelta)
            default:
                return .streamEvent(.other)     // signature_delta etc
            }
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            return .streamEvent(.blockStart(kind: (block?["type"] as? String) ?? "?"))
        case "content_block_stop":
            return .streamEvent(.blockStop)
        case "message_delta":
            let delta = event["delta"] as? [String: Any]
            return .streamEvent(.messageDelta(stopReason: delta?["stop_reason"] as? String))
        default:
            return .streamEvent(.other)         // message_start / message_stop
        }
    }

    private static func assistant(_ obj: [String: Any]) -> StreamEvent {
        guard let message = obj["message"] as? [String: Any] else {
            return .ignored(forensic: nil)
        }
        var blocks: [StreamEvent.AssistantBlock] = []
        for block in (message["content"] as? [[String: Any]]) ?? [] {
            switch block["type"] as? String {
            case "text":
                blocks.append(.text((block["text"] as? String) ?? ""))
            case "thinking":
                blocks.append(.thinking)
            case "tool_use":
                let name = (block["name"] as? String) ?? "?"
                blocks.append(.toolUse(
                    name: name,
                    activity: humanize(name: name, input: block["input"] as? [String: Any] ?? [:])
                ))
            default:
                break
            }
        }
        return .assistant(blocks, usage: usage(message["usage"] as? [String: Any]))
    }

    /// `{"input_tokens":4,"cache_read_input_tokens":38102,
    /// "cache_creation_input_tokens":1291,"output_tokens":118}`. A message whose
    /// counts are all zero (or absent) reports nothing rather than a confident 0%
    /// — the meter would rather stay dark than lie about an empty window.
    private static func usage(_ obj: [String: Any]?) -> TokenUsage? {
        guard let obj else { return nil }
        var u = TokenUsage()
        u.inputTokens = (obj["input_tokens"] as? Int) ?? 0
        u.cacheReadTokens = (obj["cache_read_input_tokens"] as? Int) ?? 0
        u.cacheCreationTokens = (obj["cache_creation_input_tokens"] as? Int) ?? 0
        u.outputTokens = (obj["output_tokens"] as? Int) ?? 0
        return u.contextInUse > 0 ? u : nil
    }

    /// `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed",
    /// "resetsAt":1787104800,"rateLimitType":"five_hour",
    /// "isUsingOverage":false}}` — camelCase and a unix stamp here, snake_case
    /// and ISO-8601 on the HTTP endpoint. The CLI's two mouths don't agree, so
    /// both shapes get their own reader.
    private static func rateLimit(_ obj: [String: Any]) -> StreamEvent {
        guard let info = obj["rate_limit_info"] as? [String: Any] else {
            return .ignored(forensic: nil)
        }
        return .rateLimit(
            type: info["rateLimitType"] as? String,
            resetsAt: (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
            isUsingOverage: (info["isUsingOverage"] as? Bool) ?? false
        )
    }

    private static func user(_ obj: [String: Any]) -> StreamEvent {
        // tool results ride user messages; plain-text user events (the
        // interrupt echo, replays) carry nothing bob renders — turns are local.
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return .ignored(forensic: nil) }
        var sawToolResult = false
        var isError = false
        for block in blocks where (block["type"] as? String) == "tool_result" {
            sawToolResult = true
            if (block["is_error"] as? Bool) == true { isError = true }
        }
        return sawToolResult ? .toolResult(isError: isError) : .ignored(forensic: nil)
    }

    private static func result(_ obj: [String: Any]) -> StreamEvent {
        var r = TurnResult()
        r.subtype = obj["subtype"] as? String
        r.isError = (obj["is_error"] as? Bool) ?? false
        r.text = obj["result"] as? String
        r.terminalReason = obj["terminal_reason"] as? String
        r.stopReason = obj["stop_reason"] as? String
        r.numTurns = obj["num_turns"] as? Int
        r.durationMs = obj["duration_ms"] as? Int
        r.costUSD = obj["total_cost_usd"] as? Double
        r.deniedTools = ((obj["permission_denials"] as? [[String: Any]]) ?? [])
            .compactMap { $0["tool_name"] as? String }
        return .result(r)
    }

    /// "reading Foo.swift" — one shared tool vocabulary across minion panels,
    /// session panels and live sessions. `TranscriptParser.humanizeTool` is
    /// private, so this goes through `ingest`, its internal front door.
    private static func humanize(name: String, input: [String: Any]) -> String {
        var update = TranscriptParser.Update()
        let synthetic: [String: Any] = [
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "name": name, "input": input]]],
        ]
        TranscriptParser.ingest(synthetic, flavor: .minionStream, into: &update)
        return update.events.first?.text ?? name.lowercased()
    }
}
