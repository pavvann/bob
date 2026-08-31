import SwiftUI

/// One row the picker can offer, whichever provider found it. The two loaders
/// differ completely — claude's is a directory of jsonl transcripts read off
/// disk, codex's is one `thread/list` RPC — but the list, the filter and the
/// keyboard are the same gesture, so they meet here rather than in a second
/// overlay.
struct ResumeCandidate: Identifiable, Equatable {
    /// What picking this row actually resumes. The payload is the provider's own
    /// handle, kept whole so `pick` never has to reconstruct one.
    enum Handle: Equatable {
        case claudeConversation(id: UUID, file: URL)
        case codexThread(id: String)
    }

    /// Stable across providers: claude ids are UUIDs, codex thread ids are
    /// UUIDv7 strings, and `ForEach` only needs them not to collide.
    let id: String
    let title: String
    let lastActivity: Date
    /// Prompts, when the provider counts them. `thread/list` doesn't — its rows
    /// carry no turn count (`turns` is populated only by resume/read) and the
    /// only other place the number lives is the rollout file, which bob does not
    /// open. nil prints nothing rather than "0 prompts".
    let prompts: Int?
    let branch: String?
    /// `bubble.left` for a chat, `terminal` for a terminal session.
    let glyph: String
    let handle: Handle
}

extension ResumeCandidate {
    init(claude conversation: ResumeIndex.Conversation) {
        self.init(
            id: conversation.id.uuidString,
            title: conversation.title,
            lastActivity: conversation.lastActivity,
            prompts: conversation.prompts,
            branch: conversation.gitBranch,
            glyph: conversation.fromBob ? "bubble.left" : "terminal",
            handle: .claudeConversation(id: conversation.id, file: conversation.fileURL)
        )
    }

    init(codex thread: CodexThreadRow) {
        self.init(
            id: thread.id,
            title: thread.title,
            lastActivity: thread.recency,
            prompts: nil,
            branch: thread.branch,
            glyph: thread.fromApp ? "bubble.left" : "terminal",
            handle: .codexThread(id: thread.id)
        )
    }
}

/// `/resume` — the conversations this session's project already has, and the
/// one you pick becomes the session's thread.
///
/// Deliberately shaped like the CLI's own `/resume`: the list is scoped to the
/// current project, newest first, and choosing a row continues that
/// conversation rather than starting a new one. It is a router as well as a
/// store, so any surface can raise it (either input bar types `/resume`, a tab
/// could offer it later) without the view that owns the overlay knowing who
/// asked — or which provider answered.
@MainActor
final class ResumeStore: ObservableObject {
    static let shared = ResumeStore()

    /// The session being pointed at a different thread.
    private enum Target {
        case claude(ClaudeSession)
        case codex(CodexSession)
    }
    private var target: Target?
    /// Bumped on every open and close, so a load that lands after you moved on
    /// is dropped. Replaces an identity check because re-aiming the picker at
    /// the *same* session has to invalidate the first read too.
    private var generation = 0

    /// Non-nil target, published: the overlay's whole gate.
    @Published private(set) var isOpen = false
    @Published private(set) var rows: [ResumeCandidate] = []
    @Published private(set) var loading = false
    @Published var query = ""
    /// The conversation the target session is already in. It stays in the list —
    /// picking it re-reads the thread instead of switching threads, which is the
    /// only way to get a restored tab's own history back on screen.
    @Published private(set) var currentID: String?
    /// The read failed rather than came back empty. Kept apart from an empty
    /// list on purpose: "app-server would not start" and "this project has no
    /// threads" are different sentences, and `try?` said the second when it
    /// meant the first.
    @Published private(set) var failure: String?
    /// The project whose history is on screen — shown in the header so a
    /// picker raised from the wrong tab is obvious before you click.
    private(set) var projectName: String = ""
    private(set) var provider: SessionProvider = .claude
    /// Which app-server the codex loader asks. The shared one in the app; a
    /// harness points it at one that cannot start, which is the only way to see
    /// what this store does when `thread/list` fails rather than answers empty.
    var codexServer: CodexServer = CodexServer.shared

    /// Filter as you type, over the title and the branch — the two things you
    /// actually remember about a conversation you want back.
    var matches: [ResumeCandidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.lowercased().contains(q)
                || ($0.branch?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - claude

    func open(for session: ClaudeSession) {
        let gen = begin(.claude(session), provider: .claude, project: session.config.name)
        let cwd = session.config.cwd
        let current = session.config.sessionId
        currentID = current.uuidString
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ResumeIndex.conversations(for: cwd)
            }.value
            guard gen == self.generation else { return }   // you moved on; drop it
            // A one-prompt errand bob ran for itself is not a destination. The
            // thread you're already in is: after a relaunch the tab holds the
            // right conversation and an empty stage, and this row is what puts it
            // back — the newest messages you have are in there, not in the
            // older thread you'd otherwise settle for.
            self.rows = found
                .filter { $0.id == current || !$0.isOneShot }
                .map(ResumeCandidate.init(claude:))
            self.loading = false
        }
    }

    // MARK: - codex

    func open(for session: CodexSession) {
        let gen = begin(.codex(session), provider: .codex, project: session.config.name)
        let cwd = session.config.cwd
        // `resumeThreadId` is the fallback that matters, not a nicety: a tab
        // restored from the state file is cold, so it has no live `threadId`
        // yet — and it is precisely that tab (right conversation, empty stage)
        // whose own row has to be marked and pickable (#32).
        currentID = session.threadId ?? session.config.resumeThreadId
        Task {
            do {
                let found = try await self.codexServer.threads(cwd: cwd, limit: 40)
                guard gen == self.generation else { return }
                self.rows = found.map(ResumeCandidate.init(codex:))
            } catch {
                guard gen == self.generation else { return }
                // app-server missing, refusing to start, or answering in a shape
                // bob doesn't know — all of which `CodexServerError` says in
                // words. Showing them beats an empty list that blames the project.
                self.failure = (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
            }
            self.loading = false
        }
    }

    // MARK: - open / close

    private func begin(_ target: Target, provider: SessionProvider, project: String) -> Int {
        generation += 1
        self.target = target
        self.provider = provider
        projectName = project
        query = ""
        rows = []
        currentID = nil
        failure = nil
        loading = true
        isOpen = true
        return generation
    }

    func close() {
        generation += 1
        target = nil
        rows = []
        query = ""
        loading = false
        currentID = nil
        failure = nil
        isOpen = false
    }

    // MARK: - picking

    /// Hand the row to whoever the picker was aimed at.
    ///
    /// Claude reads the conversation off disk first — a long transcript is real
    /// work, and the session is only touched once there's something to show.
    /// Picking the conversation you're already in is a *reload*, not a resume:
    /// the id doesn't move, the process isn't torn down, and the thread you were
    /// having comes back on screen. Picking any other one repoints the tab, and
    /// the registry is told so the next launch doesn't undo it.
    ///
    /// Codex needs no read at all: `thread/resume` hands the turns back with the
    /// thread, which is the only place bob will take them from.
    func pick(_ row: ResumeCandidate) {
        guard let target else { return }
        close()
        switch (target, row.handle) {
        case (.claude(let session), .claudeConversation(let id, let file)):
            let reloading = id == session.config.sessionId
            Task {
                let turns = await Task.detached(priority: .userInitiated) {
                    ResumeIndex.history(of: file)
                }.value
                let history = turns.map {
                    TranscriptEntry(role: $0.fromYou ? .you : .bob, text: $0.text)
                }
                if reloading {
                    session.reload(history: history, deliberate: true)
                } else {
                    session.resume(conversationId: id, history: history)
                }
            }
        case (.codex(let session), .codexThread(let threadId)):
            session.repoint(to: threadId)
        default:
            break   // a row from a picker that has since been re-aimed
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
                    prompt: Text(store.provider == .codex ? "resume a codex thread…"
                                                          : "resume a conversation…")
                        .foregroundStyle(.secondary.opacity(0.55))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .focused($focused)
                .onSubmit { if let first = store.matches.first { store.pick(first) } }
                .onKeyPress(.escape) {
                    store.close()
                    return .handled
                }
                if let glyph = store.provider.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.5))
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
                        hint(store.provider == .codex ? "asking codex what it has…"
                                                      : "reading this project's history…")
                    } else if let failure = store.failure {
                        // not "no threads": the list never arrived
                        Text("couldn't ask codex — \(failure)")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.orange.opacity(0.85))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if store.rows.isEmpty {
                        // codex matches a thread's directory *exactly* and lists
                        // nothing at all for a thread that never spoke, so the
                        // empty state says which of those it is instead of
                        // calling the project historyless
                        hint(store.provider == .codex
                             ? "no codex threads recorded in this exact directory"
                             : "no other conversations in this project yet")
                    } else if store.matches.isEmpty {
                        hint("nothing matches")
                    }
                    ForEach(store.matches) { row in
                        ResumeRow(candidate: row,
                                  isCurrent: row.id == store.currentID) { store.pick(row) }
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
    let candidate: ResumeCandidate
    /// The thread this tab is already in — picking it re-reads rather than
    /// switches, and the row says so rather than looking like a duplicate.
    var isCurrent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isCurrent ? "arrow.clockwise" : candidate.glyph)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if isCurrent {
                            Text("this thread")
                            Text("·")
                        }
                        Text(Self.ago(candidate.lastActivity))
                        if let prompts = candidate.prompts, prompts > 0 {
                            Text("·")
                            Text("\(prompts) prompt\(prompts == 1 ? "" : "s")")
                        }
                        if let branch = candidate.branch, !branch.isEmpty {
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
