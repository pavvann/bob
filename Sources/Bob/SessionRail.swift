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

    static let width: CGFloat = 196

    var body: some View {
        // Tile fills its cell by design — in a stacked rail that makes the top
        // card swallow the slack, so every card here is pinned to its content.
        VStack(alignment: .leading, spacing: 12) {
            if let branch = git.branch(for: session.config.cwd) {
                Tile(title: "branch", cornerRadius: 16) {
                    BranchCard(branch: branch, path: tidyPath)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let asked = session.question {
                Tile(title: "claude asks", cornerRadius: 16) {
                    QuestionChooser(asked: asked,
                                    onAnswer: { session.answerQuestion($0) },
                                    onDecline: { session.declineQuestion() })
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            if !session.agents.isEmpty {
                Tile(title: "agents", cornerRadius: 16) {
                    AgentRows(agents: session.agents)
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.question?.id)
        .animation(.easeInOut(duration: 0.18), value: session.agents)
        .task(id: session.id) {
            // one poll, following whichever session is on stage
            GitStatus.shared.watch(session.config.cwd)
        }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Where this session is standing.
struct BranchCard: View {
    let branch: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(branch)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(path)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// What this session has running. Finished rows linger with their one-line
/// outcome instead of vanishing, so a glance still tells you how it went.
struct AgentRows: View {
    let agents: [SessionAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(agents) { agent in
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
                        } else if let kind = agent.kind {
                            Text(kind)
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
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
