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
struct SessionQuestion: Identifiable, Equatable {
    /// The control_request id the CLI is waiting on.
    let id: String
    let toolUseId: String?
    let questions: [Ask]
    /// The tool's original `input`, echoed back untouched under the answers.
    let rawInput: [String: Any]

    struct Ask: Identifiable, Equatable {
        var id: String { question }
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
            return Ask(question: text,
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
            guard let picked = answers[ask.question], !picked.isEmpty else { continue }
            encoded[ask.question] = ask.multiSelect ? picked : picked[0]
        }
        input["answers"] = encoded
        return input
    }

    /// Every question has been answered — the reply is ready to send.
    func isComplete(_ answers: [String: [String]]) -> Bool {
        questions.allSatisfy { !(answers[$0.question] ?? []).isEmpty }
    }
}

/// One agent this session has running. The CLI calls the spawn tool `Agent`
/// (not `Task`), launches it asynchronously, and threads a single `task_id`
/// through every lifecycle event — that id is what a row is keyed on.
struct SessionAgent: Identifiable, Equatable {
    let id: String
    var description: String
    var kind: String?          // subagent_type, when the CLI names one
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
