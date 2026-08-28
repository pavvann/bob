import Foundation

/// A question claude is blocked on, and the agents a session has set running.
///
/// Both arrive on channels bob was already listening to but throwing away. The
/// question is an `AskUserQuestion` tool call, which reaches the client as a
/// `can_use_tool` control_request carrying `requires_user_interaction: true` —
/// and unlike a permission ask, the honest reply isn't yes or no, it's *which
/// one*. Answering means echoing the original questions back with an `answers`
/// map keyed by the literal question text (probe-verified 2026-08-13; the turn
/// blocks indefinitely until it arrives).
///
/// Codex asks the same kind of thing down a completely different channel
/// (`item/tool/requestUserInput`, a server-initiated JSON-RPC request) and keys
/// its answers by question id instead of question text. It lands in this same
/// type rather than a parallel one, so both providers reach the one chooser —
/// see `CodexQuestion` at the bottom of this file for that end of it.
struct SessionQuestion: Identifiable, Equatable {
    /// The control_request id the CLI is waiting on.
    let id: String
    let toolUseId: String?
    let questions: [Ask]
    /// The tool's original `input`, echoed back untouched under the answers.
    let rawInput: [String: Any]

    struct Ask: Identifiable, Equatable {
        /// What an answer for this question is keyed by. Claude keys its
        /// `answers` map by the question's literal text and codex keys its own
        /// by a question id, so the chooser can't assume either — it collects
        /// picks under this and each provider spends it its own way.
        let key: String
        var id: String { key }
        let question: String
        let header: String?
        let multiSelect: Bool
        let options: [Option]

        struct Option: Identifiable, Equatable {
            var id: String { label }
            let label: String
            let detail: String?
        }
    }

    static func == (a: SessionQuestion, b: SessionQuestion) -> Bool {
        a.id == b.id && a.questions == b.questions
    }

    /// Decoded from the raw control_request line. Returns nil when the payload
    /// isn't a question we can render — a chooser with no options to choose from
    /// would be a dead end, so bob leaves those to the permission path.
    init?(rawJSON: String, requestId: String) {
        guard let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = object["request"] as? [String: Any],
              let input = request["input"] as? [String: Any],
              let rawQuestions = input["questions"] as? [[String: Any]]
        else { return nil }

        let asks: [Ask] = rawQuestions.compactMap { entry in
            guard let text = entry["question"] as? String, !text.isEmpty else { return nil }
            let options: [Ask.Option] = ((entry["options"] as? [[String: Any]]) ?? []).compactMap {
                guard let label = $0["label"] as? String, !label.isEmpty else { return nil }
                return Ask.Option(label: label, detail: $0["description"] as? String)
            }
            guard !options.isEmpty else { return nil }
            return Ask(key: text,
                       question: text,
                       header: entry["header"] as? String,
                       multiSelect: (entry["multiSelect"] as? Bool) ?? false,
                       options: options)
        }
        guard !asks.isEmpty else { return nil }

        self.id = requestId
        self.toolUseId = request["tool_use_id"] as? String
        self.questions = asks
        self.rawInput = input
    }

    /// The `updatedInput` the CLI expects: the original input, plus answers keyed
    /// by question text. A single-select answer is the chosen label; a
    /// multi-select is the array of labels.
    func updatedInput(answers: [String: [String]]) -> [String: Any] {
        var input = rawInput
        var encoded: [String: Any] = [:]
        for ask in questions {
            guard let picked = answers[ask.key], !picked.isEmpty else { continue }
            encoded[ask.question] = ask.multiSelect ? picked : picked[0]
        }
        input["answers"] = encoded
        return input
    }

    /// Every question has been answered — the reply is ready to send.
    func isComplete(_ answers: [String: [String]]) -> Bool {
        questions.allSatisfy { !(answers[$0.key] ?? []).isEmpty }
    }
}

/// One thing this session has set running. The CLI reports two kinds down the
/// same channel and threads a single `task_id` through every lifecycle event —
/// that id is what a row is keyed on.
///
/// Both kinds belong on screen: a backgrounded `grep` is real work the session
/// is waiting on. What went wrong before was showing one as the other, so the
/// glyph says which it is and its colour says how it's going.
struct SessionAgent: Identifiable, Equatable {
    /// A spawned subagent, or a shell command the CLI moved to the background.
    enum Kind: Equatable {
        case agent
        case command

        /// No `robot` in SF Symbols on macOS 14 — a chip reads as a worker, and
        /// both glyphs stay legible at 10pt, which is what matters here.
        var symbol: String { self == .agent ? "cpu" : "terminal" }
    }

    let id: String
    var description: String
    var kind: Kind
    var agentType: String?     // subagent_type, when the CLI names one
    var status: Status
    var summary: String?

    enum Status: Equatable {
        case running
        case done
        case failed

        var isFinished: Bool { self != .running }
    }

    /// The CLI's status vocabulary, reduced to what a row needs to show.
    static func status(from raw: String?) -> Status {
        switch (raw ?? "").lowercased() {
        case "completed", "succeeded", "success", "done": return .done
        case "failed", "error", "killed", "cancelled", "canceled": return .failed
        default: return .running
        }
    }
}

// MARK: - codex's own question

/// `item/tool/requestUserInput`, read onto the chooser above.
///
/// The whole point of this type is that it is the *same* card: codex asks "which
/// one" for the same reason claude does, so it gets claude's chooser rather than
/// a second overlay. Only the two ends differ — how the questions arrive, and
/// how the answer is shaped — and both come off the pinned fixture at
/// `protocol/codex/0.149.0/json-schema/`, not off a summary:
///
///  - **`ToolRequestUserInputParams.json`** — `questions: [{id, header,
///    question, options: [{label, description}] | null, isOther, isSecret}]`
///    plus `isBlocking`, `itemId`, `threadId`, `turnId`, `autoResolutionMs`.
///    `id`, `header` and `question` are the required members of a question;
///    `options` is explicitly nullable.
///  - **`ToolRequestUserInputResponse.json`** — `{answers: {<questionId>:
///    {answers: [String]}}}`. Keyed by the question's **id**, never by its text
///    (which is where claude's map is keyed), and every value is itself an
///    object wrapping an array — one entry for a single pick, more for several.
///
/// Everything is read through a conditional cast and nothing is forced. The
/// request is `EXPERIMENTAL` in the schema and only arrives at all behind
/// `--enable default_mode_request_user_input`, so its shape is the least stable
/// thing bob decodes: a build that changes it has to land as a notice the owner
/// can read, never as a crash and never as a thread parked in silence.
enum CodexQuestion {
    static let method = "item/tool/requestUserInput"

    /// Everything one parse of the request line yields. `isBlocking` sits
    /// outside the verdict on purpose: a request bob can't draw still has to be
    /// filed as a park or not, and that answer exists even when the questions
    /// don't.
    struct Reading {
        let isBlocking: Bool
        /// The request's own deadline, when it declares one. Marked
        /// `@deprecated` in 0.149.0's schema ("use `isBlocking` to decide
        /// whether the request should block") and `null` in the live sample, so
        /// this is a lane that exists and is not expected to carry traffic.
        let autoResolutionMs: Int?
        let verdict: Verdict
    }

    enum Verdict {
        case ask(SessionQuestion)
        /// Nothing honest to draw. The string is the line the owner reads in the
        /// transcript, not a log line.
        case cannotDraw(String)
    }

    static func read(_ request: CodexServerRequest) -> Reading {
        let params = params(of: request.line)
        // absent is read as blocking, which is the conservative half of the
        // guess: claiming a park that isn't one is a wrong word in the rail,
        // while missing a real one hides a thread that has stopped moving
        let blocking = (params["isBlocking"] as? Bool) ?? true
        let auto = (params["autoResolutionMs"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        return Reading(isBlocking: blocking,
                       autoResolutionMs: auto,
                       verdict: verdict(request: request, params: params))
    }

    private static func verdict(request: CodexServerRequest, params: [String: Any]) -> Verdict {
        guard let raw = params["questions"] as? [[String: Any]], !raw.isEmpty else {
            return .cannotDraw("codex asked for input but sent no questions bob could read")
        }
        var asks: [SessionQuestion.Ask] = []
        var seen: Set<String> = []
        for entry in raw {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let text = (entry["question"] as? String)?.trimmedLine, !text.isEmpty
            else {
                return .cannotDraw("codex asked a question with no id or no text — bob can't answer that shape")
            }
            // the answer is a map keyed by id, so two questions sharing one id
            // means one of the two answers silently replaces the other
            guard seen.insert(id).inserted else {
                return .cannotDraw("codex asked two questions with the same id (\(id)) — one answer would overwrite the other")
            }
            // bob has no field that keeps a typed secret out of the transcript,
            // and a list of buttons is the wrong shape for one anyway
            if (entry["isSecret"] as? Bool) == true {
                return .cannotDraw("codex is asking for something secret (\(text)) — bob has no field that keeps it out of the transcript")
            }
            let options: [SessionQuestion.Ask.Option] =
                ((entry["options"] as? [[String: Any]]) ?? []).compactMap {
                    guard let label = ($0["label"] as? String)?.trimmedLine, !label.isEmpty else { return nil }
                    return SessionQuestion.Ask.Option(label: label, detail: $0["description"] as? String)
                }
            // `options` is nullable in the schema, and a chooser with nothing to
            // choose from is a dead end — the same call claude's decoder makes
            guard !options.isEmpty else {
                return .cannotDraw("codex asked an open question (\(text)) — a chooser has no options to offer for it")
            }
            // `isOther` is read and deliberately not rendered. It invites free
            // text alongside the options, and a card that is a list of buttons
            // has no honest place to put a text field — bob's free-text lane is
            // the input bar under the transcript, which steers straight into the
            // live turn. The options offered are still all offered.
            asks.append(SessionQuestion.Ask(
                key: id,
                question: text,
                header: entry["header"] as? String,
                // codex's schema carries no multi-select flag: one question, one
                // pick. `answers` being an array is what a future one would use
                // rather than a second field here.
                multiSelect: false,
                options: options))
        }
        return .ask(SessionQuestion(codexRequestKey: CodexApproval.key(request.id),
                                    itemId: request.itemId,
                                    questions: asks))
    }

    /// The `ToolRequestUserInputResponse` result for what the owner picked:
    /// `answers` keyed by question id, each value `{answers: [labels]}`.
    ///
    /// A question with no pick is left **out** of the map rather than sent as an
    /// empty array. The schema puts no required keys inside `answers`, so an
    /// absent key is silence about that question while `[]` would be an answer
    /// meaning "nothing" — and bob may only ever report what was actually
    /// clicked.
    static func result(for asked: SessionQuestion, picked: [String: [String]]) -> [String: Any] {
        var answers: [String: Any] = [:]
        for ask in asked.questions {
            guard let labels = picked[ask.key]?.filter({ !$0.isEmpty }), !labels.isEmpty else { continue }
            answers[ask.key] = ["answers": labels]
        }
        return ["answers": answers]
    }

    /// "you pick" — the owner declined to choose.
    ///
    /// `{answers: {}}` is schema-valid: `answers` is the response's one required
    /// member and it declares `additionalProperties` with no required keys, so
    /// an empty map is the only way to say "no answers" without bob inventing a
    /// label. It is the nearest thing codex's protocol has to claude's
    /// `behavior: deny` on an AskUserQuestion — the model reads it in place of
    /// an answer and carries on.
    static var noAnswer: [String: Any] { ["answers": [String: Any]()] }

    private static func params(of line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object["params"] as? [String: Any] ?? [:]
    }
}

extension SessionQuestion {
    /// A codex question. `rawInput` stays empty: codex's answer echoes nothing
    /// back — `CodexQuestion.result` builds the whole reply out of the picks —
    /// so there is no original input to carry, and `updatedInput` above stays
    /// claude's alone.
    init(codexRequestKey: String, itemId: String?, questions: [Ask]) {
        self.id = codexRequestKey
        self.toolUseId = itemId
        self.questions = questions
        self.rawInput = [:]
    }
}

private extension String {
    var trimmedLine: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
