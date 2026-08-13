import SwiftUI
import AppKit

/// Click a file in the tree and it opens here: a floating window with the file
/// in it, in the same glass language as the session panels.
///
/// A reader, not an editor. Markdown renders; everything else is monospace with
/// line numbers. Big files are truncated and say so, and something that isn't
/// text says that rather than spraying bytes at you.
@MainActor
final class FileViewerController: NSObject, NSWindowDelegate {
    static let shared = FileViewerController()

    private var panels: [URL: NSPanel] = [:]

    func show(_ url: URL) {
        if let existing = panels[url] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = url.lastPathComponent
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 360, height: 280)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FileViewerView(url: url))
        place(panel)
        panels[url] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        for panel in panels.values where panel.isVisible { panel.close() }
    }

    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let cascade = CGFloat(panels.count % 5) * 26
        var origin = NSPoint(x: mouse.x + 20 + cascade, y: mouse.y - size.height / 2 - cascade)
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - size.width - 12))
            origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - size.height - 12))
        }
        panel.setFrameOrigin(origin)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else { return }
        Task { @MainActor in
            panels = panels.filter { $0.value !== panel }
        }
    }
}

struct FileViewerView: View {
    let url: URL

    @State private var contents: Contents = .loading

    enum Contents {
        case loading
        case text(String, truncated: Bool)
        case markdown(String)
        case binary(Int)
        case unreadable(String)
    }

    /// A generous cap: enough for any source file, short of trying to lay out a
    /// megabyte of minified javascript in a floating window.
    private static let ceiling = 400_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.15)
            body(for: contents)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
        }
        .task(id: url) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.9))
            Text(tidyParent)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Button {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func body(for contents: Contents) -> some View {
        switch contents {
        case .loading:
            note("reading…")
        case .unreadable(let why):
            note(why)
        case .binary(let bytes):
            note("not text — \(bytes / 1024)KB")
        case .markdown(let text):
            ScrollView {
                MarkdownText(text: text, size: 13)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .textSelection(.enabled)
            }
        case .text(let text, let truncated):
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    numbered(text)
                    if truncated {
                        Text("… truncated")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    /// Line numbers in a fixed gutter, so wrapping never happens and the code
    /// keeps its shape — the panel scrolls in both directions instead.
    private func numbered(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let width = String(lines.count).count
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%\(width)d", index + 1))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.28))
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.86))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tidyParent: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.deletingLastPathComponent().path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func load() async {
        let target = url
        let loaded = await Task.detached(priority: .userInitiated) { () -> Contents in
            guard let data = try? Data(contentsOf: target, options: .mappedIfSafe) else {
                return .unreadable("couldn't read this file")
            }
            let size = data.count
            let slice = size > Self.ceiling ? data.prefix(Self.ceiling) : data
            guard let text = String(data: slice, encoding: .utf8) else {
                return .binary(size)
            }
            let markdown = ["md", "markdown"].contains(target.pathExtension.lowercased())
            return markdown ? .markdown(text) : .text(text, truncated: size > Self.ceiling)
        }.value
        contents = loaded
    }
}
