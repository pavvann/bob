import SwiftUI

/// `/resume` — the conversations this session's project already has, and the
/// one you pick becomes the session's thread.
///
/// Deliberately shaped like the CLI's own `/resume`: the list is scoped to the
/// current project, newest first, and choosing a row continues that
/// conversation rather than starting a new one. It is a router as well as a
/// store, so any surface can raise it (the input bar types `/resume`, a tab
/// could offer it later) without the view that owns the overlay knowing who
/// asked.
@MainActor
final class ResumeStore: ObservableObject {
    static let shared = ResumeStore()

    /// The session being pointed at a different thread. Non-nil = picker up.
    @Published private(set) var target: ClaudeSession?
    @Published private(set) var rows: [ResumeIndex.Conversation] = []
    @Published private(set) var loading = false
    @Published var query = ""

    /// The project whose history is on screen — shown in the header so a
    /// picker raised from the wrong tab is obvious before you click.
    private(set) var projectName: String = ""

    var isOpen: Bool { target != nil }

    /// Filter as you type, over the title and the branch — the two things you
    /// actually remember about a conversation you want back.
    var matches: [ResumeIndex.Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q) || ($0.gitBranch?.lowercased().contains(q) ?? false)
        }
    }

    func open(for session: ClaudeSession) {
        target = session
        query = ""
        rows = []
        loading = true
        projectName = session.config.name
        let cwd = session.config.cwd
        let current = session.config.sessionId
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ResumeIndex.conversations(for: cwd)
            }.value
            guard self.target === session else { return }   // you moved on; drop it
            // the thread you're already in isn't a destination, and neither is
            // a one-prompt errand bob ran for itself
            self.rows = found.filter { $0.id != current && !$0.isOneShot }
            self.loading = false
        }
    }

    func close() {
        target = nil
        rows = []
        query = ""
        loading = false
    }

    /// Read the conversation off disk, then hand it to the session. The read is
    /// off-actor because a long transcript is real work, and the session is only
    /// touched once there's something to show.
    func pick(_ conversation: ResumeIndex.Conversation) {
        guard let session = target else { return }
        close()
        Task {
            let turns = await Task.detached(priority: .userInitiated) {
                ResumeIndex.history(of: conversation.fileURL)
            }.value
            session.resume(
                conversationId: conversation.id,
                history: turns.map {
                    ClaudeSession.Entry(role: $0.fromYou ? .you : .bob, text: $0.text)
                }
            )
        }
    }
}

/// The overlay. Same glass, same rounded field, same hover rows as the project
/// picker — this is the same gesture aimed at time instead of place.
struct ResumePicker: View {
    @ObservedObject private var store = ResumeStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $store.query,
                    prompt: Text("resume a conversation…").foregroundStyle(.secondary.opacity(0.55))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .focused($focused)
                .onSubmit { if let first = store.matches.first { store.pick(first) } }
                .onKeyPress(.escape) {
                    store.close()
                    return .handled
                }
                Text(store.projectName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if store.loading {
                        hint("reading this project's history…")
                    } else if store.rows.isEmpty {
                        hint("no other conversations in this project yet")
                    } else if store.matches.isEmpty {
                        hint("nothing matches")
                    }
                    ForEach(store.matches) { row in
                        ResumeRow(conversation: row) { store.pick(row) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 420)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial) }
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.32), radius: 18, x: 0, y: 6)
        .onExitCommand { store.close() }
        .onAppear { focused = true }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

private struct ResumeRow: View {
    let conversation: ResumeIndex.Conversation
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: conversation.fromBob ? "bubble.left" : "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(Self.ago(conversation.lastActivity))
                        if conversation.prompts > 0 {
                            Text("·")
                            Text("\(conversation.prompts)\(conversation.promptsAreAtLeast ? "+" : "") "
                                 + "prompt\(conversation.prompts == 1 && !conversation.promptsAreAtLeast ? "" : "s")")
                        }
                        if let branch = conversation.gitBranch, !branch.isEmpty {
                            Text("·")
                            Text(branch).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.08 : 0))
        }
        .onHover { hover = $0 }
    }

    /// Coarse on purpose: you're recognizing a conversation, not auditing one.
    static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60:     return "just now"
        case ..<3600:   return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3600)h ago"
        case ..<172_800: return "yesterday"
        case ..<604_800: return "\(seconds / 86_400)d ago"
        default:
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
    }
}
