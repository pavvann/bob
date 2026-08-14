import Foundation

/// Which branch a session is standing on.
///
/// Read straight out of the repo rather than shelled out for: `.git/HEAD` is one
/// small file, so this can poll often enough to feel live without paying for a
/// process each time — and bob spawns quite enough processes already.
@MainActor
final class GitStatus: ObservableObject {
    static let shared = GitStatus()

    /// Keyed by the standardized directory that was asked about.
    @Published private(set) var branches: [URL: String] = [:]

    private var watching: URL?
    private var poll: Task<Void, Never>?

    /// Follow one directory — whichever session is on stage. Switching targets
    /// cancels the previous watch, so the timer count stays at one no matter how
    /// many tabs are open.
    func watch(_ directory: URL?) {
        let target = directory?.standardizedFileURL
        guard target != watching else { return }
        watching = target
        poll?.cancel()
        guard let target else { return }
        poll = Task { [weak self] in
            await self?.refresh(target)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh(target)
            }
        }
    }

    /// The read happens off the main actor — it's small, but it's still file I/O
    /// on a three-second timer, and the UI thread has better things to do.
    private func refresh(_ directory: URL) async {
        let found = await Task.detached(priority: .utility) {
            GitStatus.branch(at: directory)
        }.value
        guard branches[directory] != found else { return }
        if let found { branches[directory] = found } else { branches.removeValue(forKey: directory) }
    }

    func branch(for directory: URL) -> String? {
        branches[directory.standardizedFileURL]
    }

    // MARK: - reading the repo

    /// The checked-out branch, or a short sha when HEAD is detached. Walks up
    /// from `directory`, because a session's cwd is often a subdirectory of the
    /// repo rather than its root, and handles the worktree case where `.git` is a
    /// file pointing elsewhere.
    nonisolated static func branch(at directory: URL) -> String? {
        var current = directory.standardizedFileURL
        for _ in 0..<12 {
            if let head = headFile(in: current), let name = parse(head) { return name }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }      // hit the filesystem root
            current = parent
        }
        return nil
    }

    /// `.git` is normally a directory; in a worktree (or a submodule) it's a file
    /// whose contents point at the real git dir.
    nonisolated private static func headFile(in directory: URL) -> String? {
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            return try? String(contentsOf: dotGit.appendingPathComponent("HEAD"), encoding: .utf8)
        }
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
              let path = pointer.split(separator: "\n").first?
                  .replacingOccurrences(of: "gitdir:", with: "")
                  .trimmingCharacters(in: .whitespaces),
              !path.isEmpty
        else { return nil }
        let gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                         : directory.appendingPathComponent(path).standardizedFileURL
        return try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
    }

    /// `ref: refs/heads/main` → `main`; a bare sha → its first seven.
    nonisolated static func parse(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            guard let name = ref.components(separatedBy: "refs/heads/").last, !name.isEmpty else { return nil }
            return name
        }
        // detached HEAD — a sha is still an answer to "where am I"
        let sha = line.prefix(while: \.isHexDigit)
        return sha.count >= 7 ? String(sha.prefix(7)) : nil
    }
}
