import Foundation

/// One `thread/list` row — a codex conversation the resume picker can offer.
///
/// Everything here comes off the wire. `path` is on those rows and is annotated
/// `[UNSTABLE]` in the schema; it is deliberately not read, here or anywhere:
/// codex owns its rollout files and its SQLite, and `thread/resume` hands the
/// turns back without bob opening either.
struct CodexThreadRow: Identifiable, Equatable, Sendable {
    let id: String
    /// The name someone gave the thread, else its first user message.
    let title: String
    let cwd: String
    /// When this conversation last counted as recent. `recencyAt` is the field
    /// whose whole job that is, and it is nullable, so the fallbacks step down
    /// through the two timestamps that are always there.
    let recency: Date
    let branch: String?
    /// `cli` / `vscode` / `appServer` / `exec` — verbatim. Codex derives it from
    /// the launching environment (bob's own probe thread came back `vscode`
    /// because of the terminal that started it), so it is worth showing and not
    /// worth reasoning from.
    let source: String

    /// A GUI host wrote this one, so it reads as a chat rather than a terminal
    /// session. Cosmetic — see `source`.
    var fromApp: Bool { source == "appServer" || source == "vscode" }
}

extension CodexThreadRow {
    init?(row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = (row["recencyAt"] as? Int)
            ?? (row["updatedAt"] as? Int)
            ?? (row["createdAt"] as? Int)
            ?? 0
        self.init(
            id: id,
            title: [name, preview].compactMap { $0 }.first(where: { !$0.isEmpty })
                ?? "(no preview)",
            cwd: (row["cwd"] as? String) ?? "",
            recency: Date(timeIntervalSince1970: TimeInterval(stamp)),
            branch: (row["gitInfo"] as? [String: Any])?["branch"] as? String,
            source: Self.source(row["source"])
        )
    }

    /// `SessionSource` is a union: the four plain kinds are bare strings, and the
    /// rest are single-key objects (`{custom: …}`, `{subAgent: …}`). A shape
    /// nobody named yet reads as unknown rather than crashing the row out of the
    /// list.
    private static func source(_ raw: Any?) -> String {
        if let word = raw as? String { return word }
        if let object = raw as? [String: Any], let key = object.keys.sorted().first { return key }
        return "unknown"
    }
}

extension CodexServer {
    /// Codex's whole resume picker in one RPC.
    ///
    /// Two params carry the weight. `sortKey` **defaults to `created_at`**, which
    /// is a different order from the one a picker wants — measured live against
    /// 0.149.0, two of six rows moved between the default and `recency_at` — so
    /// recency is asked for explicitly rather than assumed. And `sourceKinds` is
    /// deliberately absent: the schema says an omitted filter "defaults to
    /// interactive sources", which is server-side exactly the cut claude's
    /// `isOneShot` makes by hand, so sub-agent, review and compact threads never
    /// arrive to be filtered out.
    ///
    /// `cwd` is an *exact* match on the recorded directory. `~` and a trailing
    /// slash are both normalised by the server (measured), but a subdirectory or
    /// a worktree of the project matches nothing — which is why the caller has a
    /// second, unscoped read rather than a claim that the project has no history.
    func threads(cwd: URL?, limit: Int) async throws -> [CodexThreadRow] {
        _ = try await start()
        var filters: [String: Any] = ["sortKey": "recency_at", "sortDirection": "desc"]
        if let cwd { filters["cwd"] = cwd.standardizedFileURL.path }
        let listed = try await page("thread/list", limit: limit, filters: filters)
        return listed.rows.compactMap(CodexThreadRow.init(row:))
    }
}
