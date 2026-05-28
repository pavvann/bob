import Foundation

/// User-managed todos. Stored as a plain array in `~/bob/state/todos.json` —
/// bob mutates the file when the user says "add X" / "mark X done", the Swift
/// layer polls it and exposes the list to the tile. The tile can also toggle
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
    private var pollTask: Task<Void, Never>?

    private init() {
        let stateDir = BobHome.shared.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        file = stateDir.appendingPathComponent("todos.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Data("[]".utf8).write(to: file)
        }
        reload()
        startPolling()
    }

    deinit { pollTask?.cancel() }

    var open: [Todo] { todos.filter { !$0.done } }

    func toggle(_ id: String) {
        guard let idx = todos.firstIndex(where: { $0.id == id }) else { return }
        todos[idx].done.toggle()
        todos[idx].completedAt = todos[idx].done ? Date() : nil
        save()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([Todo].self, from: data), loaded != todos {
            todos = loaded
        }
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
