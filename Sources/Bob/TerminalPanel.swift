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
        init(panel: NSPanel, view: LocalProcessTerminalView) {
            self.panel = panel
            self.view = view
        }
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

        let panel = NSPanel(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = name
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.minSize = NSSize(width: 420, height: 220)
        panel.delegate = self
        panel.contentView = view
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
        return Instance(panel: panel, view: view)
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
        open[k]?.panel.title = (directory as NSString).lastPathComponent
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
