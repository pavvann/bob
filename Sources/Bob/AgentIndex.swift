import Foundation

/// The agents a conversation has running, read off disk.
///
/// The live stream only tells bob about agents *it* watched being spawned, which
/// leaves the case that matters most unlit: resume a conversation (or watch one a
/// terminal is driving) and the work already in flight is invisible. The CLI
/// writes every subagent to
/// `~/.claude/projects/<project>/<conversation>/subagents/agent-<id>.jsonl`, with
/// a `.meta.json` sidecar naming it — so the disk knows, whoever spawned them.
///
/// Status isn't in the sidecar, so it comes from the shape of the transcript's
/// tail: an agent that has stopped ends on an assistant turn with
/// `stop_reason: end_turn`; one still working ends mid-thought or mid-tool.
enum AgentIndex {

    /// Agents for one conversation, newest first.
    nonisolated static func agents(conversation: UUID, cwd: URL, limit: Int = 8) -> [SessionAgent] {
        guard let project = ResumeIndex.projectDirectory(for: cwd) else { return [] }
        let directory = project
            .appendingPathComponent(conversation.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }

        let transcripts = entries
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .sorted { ResumeIndex.modified($0) > ResumeIndex.modified($1) }

        return transcripts.prefix(limit).compactMap { agent(at: $0) }
    }

    nonisolated static func agent(at transcript: URL) -> SessionAgent? {
        let stem = transcript.deletingPathExtension().lastPathComponent   // agent-<id>
        let id = String(stem.dropFirst("agent-".count))
        guard !id.isEmpty else { return nil }

        let meta = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        var description = "an agent"
        var kind: String?
        if let data = try? Data(contentsOf: meta),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            description = (object["description"] as? String) ?? description
            kind = object["agentType"] as? String
        }

        let ending = tail(of: transcript)
        let idle = Date().timeIntervalSince(ResumeIndex.modified(transcript))
        let status: SessionAgent.Status
        if ending.ended {
            status = .done
        } else if idle > 900 {
            // hasn't finished and hasn't written in fifteen minutes: its process
            // is almost certainly gone. Saying "running" there would be a lie.
            status = .failed
        } else {
            status = .running
        }

        return SessionAgent(id: id,
                            description: description,
                            kind: .agent,          // the subagents/ directory holds nothing else
                            agentType: kind,
                            status: status,
                            summary: status == .done ? ending.lastText : nil)
    }

    /// Reads the last entries of a transcript: did it finish, and what did it say?
    private nonisolated static func tail(of url: URL, bytes: Int = 96 * 1024) -> (ended: Bool, lastText: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (false, nil) }
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let offset = max(0, size - bytes)
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return (false, nil) }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }   // partial first line

        for line in lines.reversed() {
            guard let raw = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  (object["type"] as? String) == "assistant",
                  let message = object["message"] as? [String: Any]
            else { continue }
            let ended = (message["stop_reason"] as? String) == "end_turn"
            let said = ((message["content"] as? [[String: Any]]) ?? [])
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            return (ended, oneLine(said))
        }
        return (false, nil)
    }

    /// An agent's sign-off is markdown — often a heading followed by the actual
    /// point. A one-line rail row wants the point, without the syntax: prefer the
    /// first real sentence, fall back to a heading if that's all there is.
    nonisolated static func oneLine(_ markdown: String) -> String? {
        var heading: String?
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let wasHeading = line.hasPrefix("#")
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " *_`>-"))
            line = line.replacingOccurrences(of: "**", with: "")
                       .replacingOccurrences(of: "`", with: "")
                       .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if wasHeading {
                if heading == nil { heading = line }
                continue
            }
            return String(line.prefix(140))
        }
        return heading.map { String($0.prefix(140)) }
    }
}

/// Polls the agents of whichever session is on stage.
@MainActor
final class AgentWatcher: ObservableObject {
    static let shared = AgentWatcher()

    @Published private(set) var agents: [SessionAgent] = []

    private var watching: UUID?
    private var poll: Task<Void, Never>?

    func watch(conversation: UUID?, cwd: URL?) {
        guard watching != conversation else { return }
        watching = conversation
        poll?.cancel()
        agents = []
        guard let conversation, let cwd else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) {
                    AgentIndex.agents(conversation: conversation, cwd: cwd)
                }.value
                guard !Task.isCancelled else { return }
                if self?.watching == conversation, self?.agents != found { self?.agents = found }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
}
