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

    static let width: CGFloat = 196

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
            // one poll each, following whichever session is on stage
            GitStatus.shared.watch(session.config.cwd)
            AgentWatcher.shared.watch(conversation: session.config.sessionId, cwd: session.config.cwd)
        }
        .onChange(of: session.config.sessionId) { _, id in
            // /resume points the tab at a different conversation — different agents
            AgentWatcher.shared.watch(conversation: id, cwd: session.config.cwd)
        }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 1) {
                Text(branch)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(path)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        }
    }
}

/// What this session has running. Finished rows linger with their one-line
/// outcome instead of vanishing, so a glance still tells you how it went.
struct AgentRows: View {
    let agents: [SessionAgent]

    @State private var showFinished = false

    private var working: [SessionAgent] { agents.filter { $0.status == .running } }
    private var finished: [SessionAgent] { agents.filter { $0.status != .running } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(working.isEmpty ? "nothing running" : "\(working.count) working")
                .font(.system(size: 9, weight: .medium, design: .rounded))
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
                            .font(.system(size: 7, weight: .semibold))
                        Text("\(finished.count) done")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
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
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        }
    }

    private func row(_ agent: SessionAgent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(agent.status == .running ? Color.accentColor.opacity(0.75)
                      : agent.status == .failed ? Color.orange.opacity(0.8)
                      : Color.secondary.opacity(0.4))
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.description)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(agent.status == .running ? 0.85 : 0.6))
                    .lineLimit(2)
                if let summary = agent.summary, agent.status.isFinished {
                    Text(summary)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineLimit(2)
                } else if let kind = agent.kind, agent.status == .running {
                    Text(kind)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
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
struct QuestionChooser: View {
    let asked: SessionQuestion
    let onAnswer: ([String: [String]]) -> Void
    let onDecline: () -> Void

    @State private var picked: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("claude asks")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.7))
            ForEach(asked.questions) { ask in
                VStack(alignment: .leading, spacing: 5) {
                    Text(ask.question)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(ask.options) { option in
                        optionRow(ask: ask, option: option)
                    }
                    if ask.multiSelect {
                        Text("pick any")
                            .font(.system(size: 8.5, weight: .regular, design: .rounded))
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background { Capsule().fill(.white.opacity(0.06)) }
        }
        .buttonStyle(.plain)
        .help("let claude decide, and say what it chose")
    }

    private var showsSend: Bool {
        asked.questions.count > 1 || asked.questions.contains(where: \.multiSelect)
    }

    private var ready: Bool { asked.isComplete(picked) }

    private func optionRow(ask: SessionQuestion.Ask, option: SessionQuestion.Ask.Option) -> some View {
        let chosen = (picked[ask.question] ?? []).contains(option.label)
        return Button {
            toggle(ask: ask, label: option.label)
            // the common case — one question, one pick — shouldn't need a second
            // click to mean what it obviously means
            if !showsSend { onAnswer([ask.question: [option.label]]) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(.system(size: 11, weight: chosen ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(chosen ? Color.accentColor : .primary.opacity(0.82))
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
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
        var current = picked[ask.question] ?? []
        if ask.multiSelect {
            if let index = current.firstIndex(of: label) { current.remove(at: index) } else { current.append(label) }
        } else {
            current = [label]
        }
        picked[ask.question] = current
    }
}
