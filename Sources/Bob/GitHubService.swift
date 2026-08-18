import Foundation

/// Polls the GitHub CLI (`gh`) for the work-tile signals: PRs awaiting your
/// review, your own open PRs, unread notifications. Writes state to
/// `~/bob/state/work.json` so claude can read fresh data when conversation
/// references it.
///
/// v0 deliberately shells out to `gh` instead of hitting the REST API directly —
/// `gh auth` already handles token storage and refresh on the user's mac.
@MainActor
final class GitHubService: ObservableObject {
    static let shared = GitHubService()

    struct PR: Codable, Equatable, Identifiable {
        var id: String { "\(repo)#\(number)" }
        let number: Int
        let title: String
        let url: String
        let repo: String  // owner/repo
    }

    /// What the tile renders — no timestamp, so equality means "the same tile".
    /// The freshness stamp belongs to the disk mirror, not to the UI: a fresh
    /// `Date()` in here guaranteed a whole-window invalidation every 180s whether
    /// or not github had anything new to say.
    struct State: Codable, Equatable {
        let reviewRequests: [PR]
        let openPRs: [PR]
        let unreadNotifications: Int
        let ghAvailable: Bool
        let lastError: String?

        enum CodingKeys: String, CodingKey {
            case reviewRequests = "review_requests"
            case openPRs = "open_prs"
            case unreadNotifications = "unread_notifications"
            case ghAvailable = "gh_available"
            case lastError = "last_error"
        }
    }

    /// The `~/bob/state/work.json` mirror, which claude reads and does want to
    /// know the age of.
    private struct Snapshot: Encodable {
        let state: State
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }

        func encode(to encoder: Encoder) throws {
            try state.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    @Published private(set) var state: State?

    private let stateFile: URL
    private var pollingTask: Task<Void, Never>?
    private let pollIntervalSec: UInt64 = 180

    private init() {
        let stateDir = BobHome.shared.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        self.stateFile = stateDir.appendingPathComponent("work.json")

        loadCached()
        startPolling()
    }

    deinit {
        pollingTask?.cancel()
    }

    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: (self?.pollIntervalSec ?? 180) * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        guard let ghPath = Self.findGh() else {
            update(.init(reviewRequests: [], openPRs: [], unreadNotifications: 0,
                         ghAvailable: false, lastError: "gh CLI not installed"))
            return
        }

        // Check auth.
        let auth = await runProcess(executable: ghPath, args: ["auth", "status"])
        guard auth.exitCode == 0 else {
            update(.init(reviewRequests: [], openPRs: [], unreadNotifications: 0,
                         ghAvailable: false,
                         lastError: "gh not authed — run `gh auth login` in your terminal"))
            return
        }

        let (reviewRequests, openPRs) = await fetchPRs(ghPath: ghPath)
        let notifs = await fetchNotifications(ghPath: ghPath)

        update(.init(reviewRequests: reviewRequests,
                     openPRs: openPRs,
                     unreadNotifications: notifs,
                     ghAvailable: true,
                     lastError: nil))
    }

    // MARK: gh queries

    /// Returns (reviewRequests, ownOpenPRs) with full PR detail.
    private func fetchPRs(ghPath: String) async -> ([PR], [PR]) {
        let fields = "number,title,url,repository"
        let reviewQ = await runProcess(executable: ghPath, args: [
            "search", "prs",
            "--state", "open",
            "--review-requested", "@me",
            "--json", fields,
            "--limit", "20",
        ])
        let reviewPRs = Self.parsePRs(from: reviewQ.stdout)

        let mineQ = await runProcess(executable: ghPath, args: [
            "search", "prs",
            "--state", "open",
            "--author", "@me",
            "--json", fields,
            "--limit", "20",
        ])
        let minePRs = Self.parsePRs(from: mineQ.stdout)

        return (reviewPRs, minePRs)
    }

    /// `gh search prs --json number,title,url,repository` returns a JSON array
    /// where each item has `repository.nameWithOwner`. Flatten into `PR`.
    private static func parsePRs(from data: Data) -> [PR] {
        struct Raw: Decodable {
            let number: Int
            let title: String
            let url: String
            let repository: Repo
            struct Repo: Decodable { let nameWithOwner: String }
        }
        guard let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raws.map { PR(number: $0.number, title: $0.title, url: $0.url, repo: $0.repository.nameWithOwner) }
    }

    private func fetchNotifications(ghPath: String) async -> Int {
        // `gh api notifications` returns unread only by default.
        let result = await runProcess(executable: ghPath, args: [
            "api", "notifications",
        ])
        if result.exitCode != 0 { return 0 }
        let items = (try? JSONSerialization.jsonObject(with: result.stdout) as? [Any]) ?? []
        return items.count
    }

    // MARK: state

    /// The publish is guarded; the write isn't, so `work.json`'s `updated_at`
    /// still says when we last actually asked github. It goes off-main either way.
    private func update(_ new: State) {
        if new != state { state = new }
        StateMirror.write(Snapshot(state: new, updatedAt: Date()), to: stateFile)
    }

    private func loadCached() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode(State.self, from: data) {
            self.state = cached
        }
    }

    // MARK: helpers

    private static func findGh() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "\(NSHomeDirectory())/.local/bin/gh",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private nonisolated func runProcess(executable: String, args: [String]) async -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // gh uses HOME for config; preserve it.
                process.environment = ProcessInfo.processInfo.environment

                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: ProcessResult(
                        stdout: out, stderr: err, exitCode: process.terminationStatus
                    ))
                } catch {
                    continuation.resume(returning: ProcessResult(
                        stdout: Data(), stderr: Data(), exitCode: -1
                    ))
                }
            }
        }
    }
}
