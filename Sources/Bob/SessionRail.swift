import SwiftUI

/// The gutter beside a work session: what you'd otherwise have to ask for.
///
/// Bob's stage is a fixed column in a wide window, so there is real space to the
/// right of it doing nothing. This puts the session's standing context there —
/// which branch you're on, anything claude is waiting on you to choose, and the
/// agents this session has set running — in that order, because that's the order
/// you need them in: where am I, what's blocked, what's working.
struct SessionRail: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject private var git = GitStatus.shared

    static let width: CGFloat = 196

    private var branch: String? { git.branch(for: session.config.cwd) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if branch != nil {
                Tile(title: "branch", cornerRadius: 16) { branchBody }
            }
            Spacer(minLength: 0)
        }
        .frame(width: Self.width, alignment: .top)
        .task(id: session.id) {
            // one poll, following whichever session is on stage
            GitStatus.shared.watch(session.config.cwd)
        }
    }

    private var branchBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(branch ?? "—")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Text(tidyPath)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
