import SwiftUI
import AppKit

/// Click a file in the tree and it opens here: one floating window, with a tab
/// per file, in the same glass language as the session panels.
///
/// A reader, not an editor. Markdown renders; everything else is monospace with
/// line numbers. Big files are truncated and say so, and something that isn't
/// text says that rather than spraying bytes at you.
///
/// One window rather than one per file: reading three files means three tabs,
/// not three windows to arrange. And the window remembers the size you gave it —
/// `setFrameAutosaveName` is AppKit's own memory for that, so resizing once is
/// the last time you have to.
@MainActor
final class FileViewerController: NSObject, NSWindowDelegate {
    static let shared = FileViewerController()

    private let open = OpenFiles()
    private var panel: NSPanel?

    /// The key AppKit stores the frame under. Changing it forgets every size the
    /// owner has already chosen, so it doesn't change.
    private static let frameKey = "bob.fileViewer"

    func show(_ url: URL) {
        open.show(url)
        if panel == nil { panel = makePanel() }
        panel?.makeKeyAndOrderFront(nil)
    }

    func closeAll() {
        panel?.close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            // wider than tall by default: code is long lines, and 560pt wrapped
            // things that had no business wrapping
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
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
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 460, height: 300)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: FileViewerWindow(open: open, onEmpty: { [weak self] in self?.panel?.close() })
        )

        // A remembered frame wins; only a first-ever open gets placed by the
        // mouse. Order matters — autosaving after the frame is set is what makes
        // AppKit restore instead of overwrite.
        let remembered = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameKey)") != nil
        if !remembered { place(panel) }
        panel.setFrameAutosaveName(Self.frameKey)
        return panel
    }

    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 20, y: mouse.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - size.width - 12))
            origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - size.height - 12))
        }
        panel.setFrameOrigin(origin)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            panel = nil
            open.closeEverything()
        }
    }
}

/// Which files are open, and which one you're looking at.
@MainActor
final class OpenFiles: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published var selected: URL?

    func show(_ url: URL) {
        if !files.contains(url) { files.append(url) }
        selected = url
    }

    /// Closing the tab you're on lands you on its neighbour, not on nothing.
    func close(_ url: URL) {
        guard let index = files.firstIndex(of: url) else { return }
        files.remove(at: index)
        if selected == url {
            selected = files.indices.contains(index) ? files[index] : files.last
        }
    }

    func closeEverything() {
        files = []
        selected = nil
    }
}

/// The window: a tab per open file over whichever one is selected.
struct FileViewerWindow: View {
    @ObservedObject var open: OpenFiles
    let onEmpty: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
            Divider().opacity(0.15)
            if let url = open.selected {
                FileViewerView(url: url)
                    .id(url)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea()
        }
        .onChange(of: open.files.isEmpty) { _, empty in
            if empty { onEmpty() }   // last tab closed: the window goes with it
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(open.files, id: \.self) { url in
                    FileTab(url: url,
                            isActive: url == open.selected,
                            select: { open.selected = url },
                            close: { open.close(url) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }
}

/// One tab. Shaped like the session tabs along the band's bottom, because it is
/// the same idea: a thing you can put on stage, and close.
private struct FileTab: View {
    let url: URL
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: isActive ? .medium : .regular, design: .rounded))
                .foregroundStyle(isActive ? Color.primary.opacity(0.92) : Color.secondary.opacity(0.7))
                .lineLimit(1)
            if hover || isActive {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.14) : .white.opacity(hover ? 0.08 : 0.04))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.35) : .white.opacity(0.06), lineWidth: 0.5)
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
    }
}

struct FileViewerView: View {
    let url: URL

    @State private var contents: Contents = .loading

    enum Contents {
        case loading
        case text(lines: [AttributedString], truncated: Bool)
        case markdown(String)
        case binary(Int)
        case unreadable(String)
    }

    /// A generous cap: enough for any source file, short of trying to lay out a
    /// megabyte of minified javascript in a floating window.
    private static let ceiling = 400_000

    /// Colour stops well before that. At 400KB a single file is ~110,000 spans and
    /// half a second of parsing; a file that big is something you're scrolling
    /// through, not reading. Past here it renders plain and says nothing about it.
    private static let paintCeiling = 120_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.15)
            body(for: contents)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: url) { await load() }
    }

    private var header: some View {
        HStack(spacing: 6) {
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
        case .text(let lines, let truncated):
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    numbered(lines)
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
    /// keeps its shape — the panel scrolls in both directions instead. The lines
    /// arrive already coloured; laying them out must not do any thinking.
    private func numbered(_ lines: [AttributedString]) -> some View {
        let width = String(lines.count).count
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Text(String(format: "%\(width)d", index + 1))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.28))
                    Text(lines[index])
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(SyntaxTheme.plain)
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

    /// Read, split and colour — all of it off the main thread, once per file. The
    /// gutter then only lays out what this hands it.
    private func load() async {
        let (target, cap, paintCap) = (url, Self.ceiling, Self.paintCeiling)
        contents = await Task.detached(priority: .userInitiated) { () -> Contents in
            guard let data = try? Data(contentsOf: target, options: .mappedIfSafe) else {
                return .unreadable("couldn't read this file")
            }
            let size = data.count
            let slice = size > cap ? data.prefix(cap) : data
            guard let text = String(data: slice, encoding: .utf8) else {
                return .binary(size)
            }
            if ["md", "markdown"].contains(target.pathExtension.lowercased()) {
                return .markdown(text)         // prose, already rendered by MarkdownText
            }

            let lines = text.components(separatedBy: "\n")
            var spans: [SyntaxSpan] = []
            if slice.count <= paintCap,
               let language = SyntaxHighlighter.language(for: target.lastPathComponent) {
                spans = await SyntaxHighlighter.shared.spans(for: text, language: language)
            }
            // A blank line still needs a row's worth of height.
            return .text(lines: zip(lines, SyntaxSpan.perLine(lines, of: spans)).map {
                AttributedString(painting: $0.isEmpty ? " " : $0, spans: $1)
            }, truncated: size > cap)
        }.value
    }
}
