import AppKit
import SwiftTerm
import SwiftUI

/// A real terminal in a floating panel: a pty with a login shell in it, so `vi`,
/// `ngrok`, a dev server and anything else you would type in a terminal works.
///
/// Three decisions carry this file.
///
/// **Closing hides, it never destroys.** A dev server cannot die because you
/// shut the window, so `windowShouldClose` orders out and returns false. The
/// panel, the view, the pty and the scrollback all stay alive, and reopening is
/// the same shell you left — not a fresh one. `LocalProcessTerminalView` owns its
/// own pty, so keeping the view is the only way to keep the process; there is no
/// model to split off from it. The shell dying is the one thing that closes a
/// panel for real, because an exited shell is a dead window.
///
/// **The login shell comes from the passwd entry, not the environment.** launchd
/// hands a GUI app a minimal environment, so `$SHELL` is not dependable when bob
/// was opened from the dock — and PATH, nvm, pnpm and aliases are the whole point
/// of a terminal. This is deliberately the opposite of `ClaudeBridge`, which
/// avoids a login shell so rc files cannot swap the claude binary underneath it.
///
/// **A separate window is what makes the keyboard work.** Esc closes a surface in
/// bob and also leaves insert mode in `vi`. Because the terminal is its own
/// window, bob's `.onKeyPress(.escape)` chain lives in the main window and never
/// sees a key the terminal is holding, so the conflict does not arise.
@MainActor
final class TerminalController: NSObject, ObservableObject, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    static let shared = TerminalController()

    /// Which projects have a terminal on screen, so the button in an input bar
    /// can light up. Panels are AppKit and change visibility behind SwiftUI's
    /// back, so every path that shows or hides one republishes this.
    @Published private(set) var showing: Set<String> = []

    /// One terminal per working directory — the project is the identity, so
    /// reopening from the same session finds the shell you left running.
    private var open: [String: Instance] = [:]

    private final class Instance {
        let panel: NSPanel
        let view: LocalProcessTerminalView
        /// The path the header shows. Its own object rather than a field, so
        /// `cd` inside the shell can move it without rebuilding the panel.
        let cwdLine: WhereLine
        init(panel: NSPanel, view: LocalProcessTerminalView, cwdLine: WhereLine) {
            self.panel = panel
            self.view = view
            self.cwdLine = cwdLine
        }
    }

    /// One published string: where the shell currently is.
    @MainActor
    final class WhereLine: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    static func tidy(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// AppKit's own memory for a window size. One key, shared: the owner sizes a
    /// terminal once and every terminal after it opens that size.
    private static let frameKey = "bob.terminal"

    // MARK: api

    private func refresh() {
        let now = Set(open.filter { $0.value.panel.isVisible }.map(\.key))
        if now != showing { showing = now }
    }

    /// Show this project's terminal, or hide it if it's already up front.
    func toggle(cwd: URL, name: String) {
        if let instance = open[cwd.path] {
            if instance.panel.isVisible, instance.panel.isKeyWindow {
                instance.panel.orderOut(nil)
            } else {
                instance.panel.makeKeyAndOrderFront(nil)
                instance.panel.makeFirstResponder(instance.view)
            }
            refresh()
            return
        }
        let instance = make(cwd: cwd, name: name)
        open[cwd.path] = instance
        instance.panel.makeKeyAndOrderFront(nil)
        instance.panel.makeFirstResponder(instance.view)
        refresh()
    }

    // MARK: building one

    private func make(cwd: URL, name: String) -> Instance {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        view.processDelegate = self
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.caretColor = .controlAccentColor
        // Let the panel's material show through the default background. Only the
        // default background goes translucent — text, caret, selection and cells
        // with their own colour stay opaque — and it needs the clear window
        // below to composite against.
        // Legibility first: this is a window you'll run `vi` in, so the glass
        // reads as glass without the text fighting a blurred desktop. One knob.
        view.backgroundOpacity = 0.7

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = name
        panel.titlebarAppearsTransparent = true
        // The title lives in the panel's own header, next to the chips, the way
        // every other bob panel does it.
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Deliberately NOT movableByWindowBackground, unlike the read-only
        // panels: dragging inside a terminal selects text. The header is the
        // handle.
        panel.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 420, height: 240)
        panel.delegate = self
        let cwdLine = WhereLine(Self.tidy(cwd.path))
        panel.contentView = NSHostingView(
            rootView: TerminalPanelView(view: view, name: name, cwdLine: cwdLine)
        )
        panel.initialFirstResponder = view

        // A remembered frame wins; a first-ever open gets placed by the mouse.
        // Order matters — autosaving after the frame is set is what makes AppKit
        // restore instead of overwrite. Each further terminal cascades off it so
        // two projects' shells don't land exactly on top of each other.
        let key = "NSWindow Frame \(Self.frameKey)"
        if UserDefaults.standard.string(forKey: key) == nil { place(panel) }
        panel.setFrameAutosaveName(Self.frameKey)
        if !open.isEmpty {
            let step = CGFloat(open.count) * 24
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + step, y: panel.frame.origin.y - step))
        }

        view.startProcess(
            executable: Self.loginShell,
            args: ["-l"],
            environment: SwiftTerm.Terminal.getEnvironmentVariables(termName: "xterm-256color"),
            currentDirectory: cwd.path
        )
        return Instance(panel: panel, view: view, cwdLine: cwdLine)
    }

    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX + 12, min(origin.x, visible.maxX - size.width - 12))
            origin.y = max(visible.minY + 12, min(origin.y, visible.maxY - size.height - 12))
        }
        panel.setFrameOrigin(origin)
    }

    /// The owner's real shell. The passwd entry is the dependable source — see
    /// the note at the top of the file about launchd's environment.
    private static var loginShell: String {
        if let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell {
            let path = String(cString: raw)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }

    private func key(of view: LocalProcessTerminalView) -> String? {
        open.first { $0.value.view === view }?.key
    }

    // MARK: NSWindowDelegate

    /// The close button hides. Killing the shell is what closes a terminal, and
    /// that is the owner's word typed into it, not a click on the chrome.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            sender.orderOut(nil)
            self.refresh()
        }
        return false
    }

    // MARK: LocalProcessTerminalViewDelegate

    /// The shell exited — `exit`, or it died. Now the window really goes, and the
    /// instance is dropped so the next open starts a fresh shell.
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? LocalProcessTerminalView, let k = key(of: view) else { return }
        open[k]?.panel.close()
        open[k] = nil
        refresh()
    }

    /// The pty already learned its new size from the view; nothing here has a
    /// second copy of it to keep in step.
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// `cd` inside the shell retitles the window, so the panel says where you
    /// actually are rather than where you started.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let view = source as? LocalProcessTerminalView, let k = key(of: view),
              let directory, !directory.isEmpty else { return }
        // The header reads this, not `panel.title` — the real title is hidden.
        open[k]?.cwdLine.text = Self.tidy(directory)
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // the shell's own title escape is noisier than the directory — ignored
    }
}

/// The terminal button at the right of an input bar. Lit while this project's
/// terminal is on screen, the same way the mic is lit while it's listening.
struct TerminalButton: View {
    let cwd: URL
    let name: String
    @ObservedObject private var terminals = TerminalController.shared

    private var isUp: Bool { terminals.showing.contains(cwd.path) }

    var body: some View {
        Button {
            TerminalController.shared.toggle(cwd: cwd, name: name)
        } label: {
            ZStack {
                Circle()
                    .fill(isUp ? Color.accentColor.opacity(0.18) : Color.clear)
                    .frame(width: 26, height: 26)
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isUp ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(isUp ? "hide the terminal" : "a terminal in \(name)")
    }
}

/// The panel's chrome, in the same glass language as the session panels: a
/// `hudWindow` material behind everything, a header that clears the traffic
/// lights with the same 26pt the other panels use, a hairline, then the
/// terminal.
///
/// The header exists because the window's own title is hidden — a
/// `fullSizeContentView` panel draws its content under the titlebar, which is
/// what put the first rows of terminal output behind the close button.
private struct TerminalPanelView: View {
    let view: LocalProcessTerminalView
    let name: String
    @ObservedObject var cwdLine: TerminalController.WhereLine

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 26)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
                TerminalSurface(view: view)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .padding(.top, 6)
            }
        }
        .frame(minWidth: 420, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
            Text(name)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            chip("folder", cwdLine.text)
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(text)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background { Capsule().fill(.white.opacity(0.06)) }
        .frame(maxWidth: 260, alignment: .trailing)
    }
}

/// Hands SwiftUI the terminal view bob is already holding. `makeNSView` returns
/// the retained instance rather than building one, which is what keeps the pty,
/// the running process and the scrollback alive across a rebuild — the same
/// reason closing the panel only orders it out.
private struct TerminalSurface: NSViewRepresentable {
    let view: LocalProcessTerminalView
    func makeNSView(context: Context) -> LocalProcessTerminalView { view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
