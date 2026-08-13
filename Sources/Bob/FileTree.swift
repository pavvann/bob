import SwiftUI

/// The project a session is working in, as a tree in the left gutter.
///
/// Deliberately not a file manager: no renaming, no dragging, no context menus.
/// It answers "what's in here" and "show me that file", which is what you
/// actually want while reading a session's reasoning about a codebase.
///
/// Children load when a folder opens and are cached, so the tree costs nothing
/// until it's used and never re-scans a directory you're staring at. Build
/// output and vendored dependencies are skipped — a `node_modules` node is a
/// hundred thousand files nobody meant to browse.
@MainActor
final class FileTreeStore: ObservableObject {
    static let shared = FileTreeStore()

    @Published private(set) var root: URL?
    @Published private(set) var children: [URL: [Node]] = [:]
    @Published var expanded: Set<URL> = []
    @Published var selected: URL?

    struct Node: Identifiable, Equatable, Sendable {
        var id: URL { url }
        let url: URL
        let name: String
        let isDirectory: Bool
    }

    /// Directories that are always noise in a project tree.
    static let skipped: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "DerivedData", "dist", "build",
        ".next", ".venv", "venv", "__pycache__", ".pytest_cache", "target", "Pods",
        ".gradle", ".idea", ".vscode", ".terraform", "vendor", ".turbo", ".cache",
    ]

    func focus(_ directory: URL?) {
        let target = directory?.standardizedFileURL
        guard target != root else { return }
        root = target
        children = [:]
        expanded = []
        selected = nil
        if let target { load(target) }
    }

    func toggle(_ node: Node) {
        guard node.isDirectory else { return }
        if expanded.contains(node.url) {
            expanded.remove(node.url)
        } else {
            expanded.insert(node.url)
            if children[node.url] == nil { load(node.url) }
        }
    }

    /// Re-read a directory that's already open (the tree is a snapshot; an agent
    /// writing a new file is exactly when you'd want to see it).
    func refresh() {
        let open = expanded
        children = [:]
        if let root { load(root) }
        for directory in open { load(directory) }
    }

    private func load(_ directory: URL) {
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                FileTreeStore.read(directory)
            }.value
            children[directory] = found
        }
    }

    /// Folders first, then files, each alphabetical and case-blind — the order a
    /// person scans in, not the order the filesystem happens to hand back.
    nonisolated static func read(_ directory: URL) -> [Node] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        return entries.compactMap { url -> Node? in
            let name = url.lastPathComponent
            guard !skipped.contains(name) else { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return Node(url: url, name: name, isDirectory: isDirectory)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// The tree itself. Rows are 20pt tall and indent by depth; a folder's children
/// appear beneath it once opened.
struct FileTree: View {
    @ObservedObject private var store = FileTreeStore.shared
    let root: URL

    static let width: CGFloat = 218

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(root.lastPathComponent)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("re-read the tree")
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(visible, id: \.node.id) { entry in
                        FileRow(node: entry.node,
                                depth: entry.depth,
                                isExpanded: store.expanded.contains(entry.node.url),
                                isSelected: store.selected == entry.node.url) {
                            if entry.node.isDirectory {
                                store.toggle(entry.node)
                            } else {
                                store.selected = entry.node.url
                                FileViewerController.shared.show(entry.node.url)
                            }
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 0.5)
        }
        // the card is exactly the gutter's width, padding included — otherwise
        // the stage shifts sideways as you move between a session and bob
        .frame(width: Self.width)
        .task(id: root) { store.focus(root) }
    }

    /// The tree flattened to the rows actually on screen — a closed folder
    /// contributes exactly one. Built iteratively rather than by a recursive
    /// view, which SwiftUI can't type, and which would rebuild every subtree on
    /// each toggle anyway.
    private var visible: [(node: FileTreeStore.Node, depth: Int)] {
        descend(root, depth: 0)
    }

    private func descend(_ directory: URL, depth: Int) -> [(node: FileTreeStore.Node, depth: Int)] {
        var rows: [(node: FileTreeStore.Node, depth: Int)] = []
        for node in store.children[directory] ?? [] {
            rows.append((node, depth))
            if node.isDirectory, store.expanded.contains(node.url) {
                rows.append(contentsOf: descend(node.url, depth: depth + 1))
            }
        }
        return rows
    }
}

private struct FileRow: View {
    let node: FileTreeStore.Node
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: node.isDirectory
                      ? (isExpanded ? "chevron.down" : "chevron.right")
                      : icon(for: node.name))
                    .font(.system(size: node.isDirectory ? 8.5 : 9.5, weight: .medium))
                    .foregroundStyle(.secondary.opacity(node.isDirectory ? 0.55 : 0.4))
                    .frame(width: 12)
                Text(node.name)
                    .font(.system(size: 12, weight: node.isDirectory ? .medium : .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary.opacity(node.isDirectory ? 0.82 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 11)
            .padding(.horizontal, 4)
            .padding(.vertical, 3.5)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14)
                          : hover ? Color.white.opacity(0.06) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rst":        return "doc.text"
        case "json", "yml", "yaml", "toml", "plist": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "sh", "zsh", "bash":                   return "terminal"
        default:                                    return "doc"
        }
    }
}
