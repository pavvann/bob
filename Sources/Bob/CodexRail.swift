import SwiftUI

/// The gutter beside a codex session — the same furniture as claude's rail, with
/// the cards codex can actually fill.
///
/// Claude's rail shows the question chooser and the agents this conversation set
/// running; codex reports its work as typed items instead, so this shows those
/// (#38 T2.3) and, above them, what the model is thinking (#38 T2.4). The
/// chooser is shared outright (#38 T2.2) — same card, same position in the
/// column, same keyboard behaviour. Same width, same card chrome, same quiet
/// tone: it is one gutter with two providers, not two gutters.
struct CodexRail: View {
    @ObservedObject var session: CodexSession
    @ObservedObject private var git = GitStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let branch = git.branch(for: session.config.cwd) {
                BranchChip(branch: branch, path: tidyPath)
            }
            // claude's card, verbatim — `item/tool/requestUserInput` asks the
            // same thing down a different channel, and the answer's shape is the
            // session's business rather than the card's
            if let asked = session.question {
                QuestionChooser(asked: asked,
                                provider: .codex,
                                onAnswer: { session.answerQuestion($0) },
                                onDecline: { session.declineQuestion() })
                    // a fresh identity per question, so the half-made picks
                    // inside the card die with the question they were for: codex
                    // can queue a second request behind the first, and two of
                    // them can reuse a question id
                    .id(asked.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            // absent entirely when the model emits no reasoning, which most do
            // not — a "thinking" row with nothing behind it is a placeholder
            if let reasoning = session.activity.reasoning, !reasoning.isEmpty {
                ThinkingRow(reasoning: reasoning)
                    .transition(.opacity)
            }
            if !session.activity.rows.isEmpty {
                CodexActivityCard(store: session.activity)
                    .transition(.opacity)
            }
        }
        .frame(width: SessionRail.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
        // the same spring claude's rail gives the same card
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: session.question?.id)
        // keyed on counts, not on the rows themselves: a row's output grows
        // sixty times a second and none of that is a layout change
        .animation(.easeInOut(duration: 0.18), value: session.activity.rows.count)
        .animation(.easeInOut(duration: 0.18), value: session.activity.reasoning?.id)
        .task(id: session.id) {
            // held for exactly as long as the rail is mounted, released on
            // `.task` cancellation — see the note on claude's rail for why
            // onAppear/onDisappear is not the hook
            GitStatus.shared.acquire(session.config.cwd)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            GitStatus.shared.release()
        }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - activity

/// What codex is doing — a command, an MCP tool, a web search, a file change.
/// Shaped exactly like claude's agent rows: a glyph whose colour says how it's
/// going, a title, a one-line caption, and a fold for what has finished.
///
/// Two departures from that card, both earned. A command's live output shows
/// under its row, because a command is the one thing claude cannot report and
/// watching it work is the whole point. And a failure never folds away: a
/// non-zero exit stays on screen next to what is still running, since a red row
/// hidden behind "4 done" is a failure you find tomorrow.
struct CodexActivityCard: View {
    let store: CodexActivityStore

    @State private var showFinished = false
    /// Which commands have been clicked open for more of their output.
    @State private var opened: Set<String> = []

    private static let tailWhileRunning = 3
    private static let tailWhenOpen = 18

    var body: some View {
        let rows = store.rows
        let standing = rows.filter { $0.isRunning || $0.failed }
        let finished = rows.filter { !($0.isRunning || $0.failed) }

        VStack(alignment: .leading, spacing: 7) {
            Text(header(rows.filter(\.isRunning)))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))

            ForEach(standing) { row($0) }

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
                .padding(.top, standing.isEmpty ? 0 : 2)

                if showFinished {
                    ForEach(finished) { row($0) }
                }
            }

            if let diff = store.turnDiff {
                Text(Self.spell(diff))
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .railCard()
    }

    /// Says what is actually running, in the same words claude's rail uses.
    private func header(_ working: [CodexActivityRow]) -> String {
        guard !working.isEmpty else { return "nothing running" }
        var tally: [CodexActivityRow.Kind: Int] = [:]
        for row in working { tally[row.kind, default: 0] += 1 }
        let words = [CodexActivityRow.Kind.command, .tool, .search, .fileChange]
            .compactMap { kind -> String? in
                guard let count = tally[kind] else { return nil }
                return "\(count) \(count == 1 ? kind.noun : kind.plural)"
            }
        // one kind reads as a sentence, several read as a list — same choice
        // claude's rail makes, for the same reason
        return words.count == 1 ? words[0] + " running" : words.joined(separator: ", ")
    }

    private static func spell(_ diff: CodexDiffTally) -> String {
        var parts: [String] = []
        if diff.added > 0 { parts.append("+\(diff.added)") }
        if diff.removed > 0 { parts.append("−\(diff.removed)") }
        if diff.files > 0 { parts.append("in \(diff.files) file\(diff.files == 1 ? "" : "s")") }
        return parts.isEmpty ? "" : parts.joined(separator: " ") + " this turn"
    }

    @ViewBuilder
    private func row(_ item: CodexActivityRow) -> some View {
        let showsOutput = item.kind == .command && !item.output.isEmpty
        let open = opened.contains(item.id)
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AgentRows.tint(for: item.tint))
                .frame(width: 12)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    // a failure keeps full weight rather than fading into the
                    // finished pile
                    .foregroundStyle(.primary.opacity(item.isRunning || item.failed ? 0.85 : 0.6))
                    .lineLimit(2)
                    // without this a row with a caption under it is squeezed to
                    // one line and its title dies in an ellipsis
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption)
                        .font(.system(size: 10.5, weight: .regular, design: .rounded))
                        .foregroundStyle(item.failed ? Color.red.opacity(0.75) : .secondary.opacity(0.5))
                        .lineLimit(1)
                }
                if showsOutput, item.isRunning || open || item.failed {
                    output(item, lines: open ? Self.tailWhenOpen : Self.tailWhileRunning)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard showsOutput else { return }
            withAnimation(.easeInOut(duration: 0.16)) {
                if open { opened.remove(item.id) } else { opened.insert(item.id) }
            }
        }
        .help(showsOutput ? (open ? "hide the output" : "show more of the output") : "")
    }

    /// The tail of what the command has printed. Monospaced and dim: it is
    /// evidence, not prose, and the gutter is 218pt wide — each line is one line.
    private func output(_ item: CodexActivityRow, lines: Int) -> some View {
        let tail = item.output.visibleLines
        let shown = Array(tail.suffix(lines))
        return VStack(alignment: .leading, spacing: 0) {
            if item.output.clipped || shown.count < tail.count {
                Text("…")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.3))
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 2)
    }
}

private extension CodexActivityRow.Kind {
    var noun: String {
        switch self {
        case .command: return "command"
        case .tool: return "tool"
        case .search: return "search"
        case .fileChange: return "edit"
        }
    }

    var plural: String {
        switch self {
        case .command: return "commands"
        case .tool: return "tools"
        case .search: return "searches"
        case .fileChange: return "edits"
        }
    }
}

private extension CodexActivityRow {
    /// Borrowed from claude's rail rather than re-picked, so the two gutters
    /// can't disagree about what green means. `declined` is the owner's own
    /// answer, not a failure — it reads as finished.
    var tint: SessionAgent.Status {
        if failed { return .failed }
        return isRunning ? .running : .done
    }
}

// MARK: - reasoning

/// What the model is working through, collapsed.
///
/// Quiet by design: one line saying it exists, and nothing else until it is
/// clicked. Reasoning is a side channel — the reply is the answer — and most
/// models emit none at all, which is why the caller only mounts this when there
/// is something in it.
struct ThinkingRow: View {
    let reasoning: CodexReasoningRow

    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Image(systemName: "brain")
                        .font(.system(size: 9.5, weight: .medium))
                    Text(reasoning.isLive ? "thinking" : "thought")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary.opacity(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                let summary = reasoning.summary
                ForEach(Array(summary.enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                // raw reasoning text is model-dependent and usually absent —
                // detail under the summary, never instead of it
                if !reasoning.raw.isEmpty {
                    Text(reasoning.raw)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .railCard()
    }
}
