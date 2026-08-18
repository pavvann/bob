import Foundation

/// User-managed todos. Stored as a plain array in `~/bob/state/todos.json` —
/// bob mutates the file when the user says "add X" / "mark X done", the Swift
/// layer watches it and exposes the list to the tile. The tile can also toggle
/// items directly (write-back).
@MainActor
final class TodoService: ObservableObject {
    static let shared = TodoService()

    struct Todo: Codable, Identifiable, Equatable {
        let id: String
        var text: String
        var done: Bool
        var createdAt: Date?
        var completedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, text, done
            case createdAt = "created_at"
            case completedAt = "completed_at"
        }
    }

    @Published private(set) var todos: [Todo] = []

    private let file: URL

    private init() {
        let stateDir = BobHome.shared.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        file = stateDir.appendingPathComponent("todos.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("[]".utf8).write(to: file)
        }

        // The read and the decode happen wherever this closure is called from —
        // the watcher's utility queue, or a detached task to seed the tile at
        // launch. Only the ==-guarded publish crosses to the main actor.
        let url = file
        let load: @Sendable ([String]) -> Void = { [weak self] _ in
            guard let loaded = Self.read(url) else { return }
            Task { @MainActor in
                guard let self, loaded != self.todos else { return }
                self.todos = loaded
            }
        }
        DirWatcher.shared.acquire(path: url.path, id: "todos", handler: load)
        DispatchQueue.global(qos: .utility).async { load([]) }
    }

    var open: [Todo] { todos.filter { !$0.done } }

    func toggle(_ id: String) {
        guard let idx = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[idx].done.toggle()
        todos[idx].completedAt = todos[idx].done ? Date() : nil
        save()
    }

    private nonisolated static func read(_ url: URL) -> [Todo]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Todo].self, from: data)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(todos) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
