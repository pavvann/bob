import Foundation

/// The models codex will run, read once from `model/list` and kept.
///
/// A menu's label and content closures run on every layout pass, so this can
/// never be an RPC a view reaches for directly: `loadIfNeeded()` is a `.task`
/// hook, fires at most one call per launch, and a failure leaves the dial with
/// "auto" — which is a working answer, not a broken one.
@MainActor
final class CodexCatalog: ObservableObject {
    static let shared = CodexCatalog()

    struct Model: Identifiable, Equatable {
        let id: String
        let displayName: String
        /// Advertised per model — `ReasoningEffort` is a free string in the
        /// schema precisely because the list differs between them, so bob has
        /// no table of its own.
        let efforts: [String]
        let defaultEffort: String?
        let isDefault: Bool
    }

    @Published private(set) var models: [Model] = []
    private var loading: Task<Void, Never>?

    func loadIfNeeded() {
        guard models.isEmpty, loading == nil, CodexServer.codexPath != nil else { return }
        loading = Task { [weak self] in
            let rows = await Self.fetch()
            guard let self else { return }
            self.adopt(rows)
            self.loading = nil
        }
    }

    /// The one place the cache is written — so a caller that paged `model/list`
    /// itself (a harness, or anything that already had the rows) primes the dial
    /// without a second round trip.
    func adopt(_ rows: [Model]) {
        guard !rows.isEmpty, models != rows else { return }
        models = rows
    }

    /// The efforts to offer for whatever model a session is on — the model's
    /// own list, and the default model's when the session hasn't named one.
    func efforts(for model: String?) -> [String] {
        if let model, let row = models.first(where: { $0.id == model }) { return row.efforts }
        return models.first(where: \.isDefault)?.efforts ?? []
    }

    /// What codex would pick on its own. A session going back to "auto" has to
    /// name these explicitly: a per-turn override persists into later turns, so
    /// dropping the field would leave the last choice running under a dial that
    /// says auto. nil when the list never loaded — then silence is all bob has.
    var defaultModelId: String? { models.first(where: \.isDefault)?.id }

    func defaultEffort(for model: String?) -> String? {
        if let model, let row = models.first(where: { $0.id == model }) { return row.defaultEffort }
        return models.first(where: \.isDefault)?.defaultEffort
    }

    private static func fetch() async -> [Model] {
        do {
            _ = try await CodexServer.shared.start()
            let page = try await CodexServer.shared.page("model/list", limit: 50)
            return page.rows.compactMap(Model.init(row:))
        } catch {
            return []
        }
    }
}

extension CodexCatalog.Model {
    init?(row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        guard (row["hidden"] as? Bool) != true else { return nil }
        self.init(
            id: id,
            displayName: (row["displayName"] as? String) ?? id,
            efforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String },
            defaultEffort: row["defaultReasoningEffort"] as? String,
            isDefault: (row["isDefault"] as? Bool) ?? false
        )
    }
}
