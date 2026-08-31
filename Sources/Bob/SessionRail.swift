import SwiftUI

/// The gutter beside a work session: what you'd otherwise have to ask for.
///
/// Bob's stage is a fixed column in a wide window, so there is real space to the
/// right of it doing nothing. This puts the session's standing context there —
/// which branch you're on, anything claude is waiting on you to choose, and the
/// agents this session has set running — in that order, because that's the order
/// you need them in: where am I, what's blocked, what's working.
///
/// The three cards take plain data and closures rather than reaching into the
/// session, so each one can be rendered and looked at without a live claude
/// behind it.
struct SessionRail: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject private var git = GitStatus.shared
    @ObservedObject private var watcher = AgentWatcher.shared

    static let width: CGFloat = 218

    /// Disk knows about every agent in this conversation, whoever spawned them —
    /// including a session bob resumed, or one a terminal is driving. The live
    /// stream can still be ahead of the first poll, so anything bob watched start
    /// and disk hasn't caught up on is folded in.
    private var agents: [SessionAgent] {
        var rows = watcher.agents
        let known = Set(rows.map(\.id))
        rows.append(contentsOf: session.agents.filter { !known.contains($0.id) })
        return rows
    }

    var body: some View {
        // centred in the gutter rather than pinned to the top: it's standing
        // context, not a header, and it reads better beside the conversation
        VStack(alignment: .leading, spacing: 10) {
            if let branch = git.branch(for: session.config.cwd) {
                BranchChip(branch: branch, path: tidyPath)
            }
            if let asked = session.question {
                QuestionChooser(asked: asked,
                                onAnswer: { session.answerQuestion($0) },
                                onDecline: { session.declineQuestion() })
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            if !agents.isEmpty {
                AgentRows(agents: agents)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.question?.id)
        .animation(.easeInOut(duration: 0.18), value: agents)
        .task(id: session.id) {
            // one watch each, following whichever session is on stage, held for
            // exactly as long as the rail is mounted. `.task` cancellation is the
            // release hook: onDisappear doesn't reliably pair with onAppear under
            // SwiftUI remounts, which is how both of these used to leak.
            GitStatus.shared.acquire(session.config.cwd)
            AgentWatcher.shared.acquire(conversation: session.config.sessionId, cwd: session.config.cwd)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            GitStatus.shared.release()
            AgentWatcher.shared.release()
        }
        .onChange(of: session.config.sessionId) { _, id in
            // /resume points the tab at a different conversation — different agents
            AgentWatcher.shared.retarget(conversation: id, cwd: session.config.cwd)
        }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// The rail's card chrome, in one place. The cards here and codex's activity
/// rows are the same piece of furniture, and a second copy of these four numbers
/// is exactly how two gutters drift apart.
extension View {
    func railCard() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 0.5)
            }
    }
}

/// Where this session is standing — shaped like the session tabs along the
/// bottom, because it belongs to the same family of "what am I looking at"
/// furniture. No label: a branch icon and a branch name need no caption.
struct BranchChip: View {
    let branch: String
    let path: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 1) {
                Text(branch)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(path)
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .railCard()
    }
}

/// What this session has running — spawned agents and the shell commands the CLI
/// moved to the background, which are both real work and were previously shown
/// as the same thing. The glyph says which it is (a chip for an agent, a prompt
/// for a command) and its colour says how it's going: green working, grey done,
/// red stopped badly. Finished rows linger with their one-line outcome instead
/// of vanishing, so a glance still tells you how it went.
struct AgentRows: View {
    let agents: [SessionAgent]

    @State private var showFinished = false

    private var working: [SessionAgent] { agents.filter { $0.status == .running } }
    private var finished: [SessionAgent] { agents.filter { $0.status != .running } }

    /// Says what is actually running, since "2 working" reads very differently
    /// when one of them is a grep.
    private var header: String {
        guard !working.isEmpty else { return "nothing running" }
        let agentCount = working.filter { $0.kind == .agent }.count
        let commandCount = working.count - agentCount
        switch (agentCount, commandCount) {
        case (let a, 0): return "\(a) agent\(a == 1 ? "" : "s") working"
        case (0, let c): return "\(c) command\(c == 1 ? "" : "s") running"
        case (let a, let c): return "\(a) agent\(a == 1 ? "" : "s"), \(c) command\(c == 1 ? "" : "s")"
        }
    }

    /// Green working, grey done, red stopped badly.
    static func tint(for status: SessionAgent.Status) -> Color {
        switch status {
        case .running: return .green.opacity(0.85)
        case .done:    return .secondary.opacity(0.45)
        case .failed:  return .red.opacity(0.8)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(header)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))

            ForEach(working) { row($0) }

            // Everything that has stopped folds away: what's running is the
            // answer to "what's happening now", and eight finished rows bury it.
            if !finished.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showFinished.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showFinished ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("\(finished.count) done")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary.opacity(0.45))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, working.isEmpty ? 0 : 2)

                if showFinished {
                    ForEach(finished) { row($0) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .railCard()
    }

    private func row(_ agent: SessionAgent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: agent.kind.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Self.tint(for: agent.status))
                .frame(width: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.description)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(agent.status == .running ? 0.85 : 0.6))
                    .lineLimit(2)
                    // without this a row with a caption under it gets squeezed to
                    // one line and the description dies in an ellipsis
                    .fixedSize(horizontal: false, vertical: true)
                if let summary = agent.summary, agent.status.isFinished {
                    Text(summary)
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineLimit(2)
                } else if let type = agent.agentType, agent.status == .running {
                    Text(type)
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The chooser. Claude's turn is stopped dead until one of these is clicked, so
/// the card states the question, lists the options with their reasons, and keeps
/// a way out — declining hands the choice back rather than leaving the session
/// hanging on a person who walked away.
///
/// One card, both providers (#38 T2.2). Codex's `item/tool/requestUserInput`
/// arrives down a different channel and answers a different shape, but it is the
/// same question — which one — so it gets this card rather than a second
/// overlay. The only thing the provider changes here is the word at the top.
/// It takes plain data and two closures precisely so that stays true.
struct QuestionChooser: View {
    let asked: SessionQuestion
    let provider: SessionProvider
    let onAnswer: ([String: [String]]) -> Void
    let onDecline: () -> Void

    @State private var picked: [String: [String]] = [:]

    /// Spelled out rather than synthesized: the memberwise init a `@State`
    /// property makes is private to this file, and codex's rail mounts this
    /// card from its own.
    init(asked: SessionQuestion,
         provider: SessionProvider = .claude,
         onAnswer: @escaping ([String: [String]]) -> Void,
         onDecline: @escaping () -> Void) {
        self.asked = asked
        self.provider = provider
        self.onAnswer = onAnswer
        self.onDecline = onDecline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(provider.rawValue) asks")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.7))
            ForEach(asked.questions) { ask in
                VStack(alignment: .leading, spacing: 5) {
                    Text(ask.question)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(ask.options) { option in
                        optionRow(ask: ask, option: option)
                    }
                    if ask.multiSelect {
                        Text("pick any")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
            }

            // A single question with one pick answers on the click itself, so
            // these only matter for the multi-question and multi-select cases.
            if showsSend {
                HStack(spacing: 6) {
                    Button { onAnswer(picked) } label: {
                        Text("send")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(ready ? Color.accentColor : .secondary.opacity(0.4))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background { Capsule().fill(Color.accentColor.opacity(ready ? 0.16 : 0.05)) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                    declineButton
                }
            } else {
                declineButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
    }

    private var declineButton: some View {
        Button { onDecline() } label: {
            Text("you pick")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background { Capsule().fill(.white.opacity(0.06)) }
        }
        .buttonStyle(.plain)
        .help(declineHint)
    }

    /// Same gesture, two protocols. Claude's decline carries a message asking it
    /// to say what it went with; codex's answer map has nowhere to put words, so
    /// its version promises less.
    private var declineHint: String {
        provider == .codex
            ? "send no answer — codex picks for itself"
            : "let claude decide, and say what it chose"
    }

    private var showsSend: Bool {
        asked.questions.count > 1 || asked.questions.contains(where: \.multiSelect)
    }

    private var ready: Bool { asked.isComplete(picked) }

    private func optionRow(ask: SessionQuestion.Ask, option: SessionQuestion.Ask.Option) -> some View {
        let chosen = (picked[ask.key] ?? []).contains(option.label)
        return Button {
            toggle(ask: ask, label: option.label)
            // the common case — one question, one pick — shouldn't need a second
            // click to mean what it obviously means
            if !showsSend { onAnswer([ask.key: [option.label]]) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(.system(size: 12.5, weight: chosen ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(chosen ? Color.accentColor : .primary.opacity(0.82))
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chosen ? Color.accentColor.opacity(0.12) : .white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(chosen ? Color.accentColor.opacity(0.4) : .white.opacity(0.06),
                                    lineWidth: chosen ? 1 : 0.5)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(ask: SessionQuestion.Ask, label: String) {
        var current = picked[ask.key] ?? []
        if ask.multiSelect {
            if let index = current.firstIndex(of: label) { current.remove(at: index) } else { current.append(label) }
        } else {
            current = [label]
        }
        picked[ask.key] = current
    }
}
