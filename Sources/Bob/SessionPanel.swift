import SwiftUI
import AppKit

/// What a floating panel is watching — one of bob's own minions, an external
/// claude code session discovered under ~/.claude/projects, or one of bob's own
/// live in-app sessions. The first two are files on disk; the third is an
/// object in this process, read straight from its published transcript.
enum PanelSource {
    case minion(MinionService.Minion)
    case external(SessionWatcher.Session)
    case live(ClaudeSession)

    /// Main-actor because a live session's config is main-actor state. Every
    /// caller is the controller, which is @MainActor anyway.
    @MainActor
    var key: String {
        switch self {
        case .minion(let m): return "minion-\(m.id)"
        case .external(let s): return "session-\(s.id)"
        case .live(let s): return "live-\(s.id)"
        }
    }

    @MainActor
    var windowTitle: String {
        switch self {
        case .minion(let m): return m.task
        case .external(let s): return s.projectName
        case .live(let s): return s.config.name
        }
    }
}

/// Owns every floating session panel — one NSPanel per minion/session, keyed
/// by id, floating above everything, any number open at once. Panels are
/// created once and toggled thereafter (`isReleasedWhenClosed = false`;
/// reopening a released panel crashes). Also tracks the main window so ⌥Space
/// and app-termination logic can tell bob apart from his panels.
@MainActor
final class SessionPanelController: NSObject {
    static let shared = SessionPanelController()

    private(set) weak var mainWindow: NSWindow?
    private var panels: [String: NSPanel] = [:]
    private var models: [String: SessionFeedModel] = [:]
    private var mainCloseObserver: NSObjectProtocol?

    func adoptMainWindow(_ window: NSWindow) {
        guard window !== mainWindow, !(window is NSPanel) else { return }
        mainWindow = window
        if let mainCloseObserver { NotificationCenter.default.removeObserver(mainCloseObserver) }
        // when bob's main window closes, take the panels down with it —
        // terminate-after-last-window only fires once they're gone too.
        mainCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in SessionPanelController.shared.closeAll() }
        }
    }

    func toggle(_ source: PanelSource) {
        let key = source.key
        if let panel = panels[key] {
            if panel.isVisible {
                panel.close()
            } else {
                models[key]?.start()
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        let model = SessionFeedModel(source: source)
        let panel = makePanel(source: source, model: model)
        panels[key] = panel
        models[key] = model
        model.start()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Float (or dismiss) a glance panel on one of bob's own live sessions —
    /// the non-active tab you want to watch while you work in another. Same
    /// toggle semantics as every other panel, keyed by session id.
    func toggleLive(session: ClaudeSession) {
        toggle(.live(session))
    }

    /// The counterpart to `SessionManager.close`: a tab the owner closed must
    /// not leave a floating panel behind, still offering to wake a session that
    /// no longer exists anywhere. Safe to call for a session that never had one.
    func forgetLive(session: ClaudeSession) {
        let key = PanelSource.live(session).key
        let panel = panels.removeValue(forKey: key)
        let model = models.removeValue(forKey: key)
        panel?.close()      // already out of the dictionaries — the delegate no-ops
        model?.stop()
    }

    func closeAll() {
        for panel in panels.values where panel.isVisible { panel.close() }
    }

    private func makePanel(source: PanelSource, model: SessionFeedModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
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
        panel.title = source.windowTitle
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 340, height: 320)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SessionPanelView(model: model))
        place(panel)
        return panel
    }

    /// Open near the card the user just clicked (i.e. the mouse), clamped
    /// on-screen, with a small cascade so stacked panels don't hide each other.
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let cascade = CGFloat(panels.count % 5) * 26
        var origin = NSPoint(x: mouse.x - size.width / 2 + cascade, y: mouse.y + 18 + cascade)
        if let vis = screen?.visibleFrame {
            origin.x = max(vis.minX + 12, min(origin.x, vis.maxX - size.width - 12))
            origin.y = max(vis.minY + 12, min(origin.y, vis.maxY - size.height - 12))
        }
        panel.setFrameOrigin(origin)
    }
}

extension SessionPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let key = panels.first(where: { $0.value === panel })?.key else { return }
        models[key]?.stop()
    }
}

// MARK: panel face

/// The panel's face: header (status, title, workdir/branch chips, clock),
/// the live feed, and the closing numbers once a minion reports in.
struct SessionPanelView: View {
    @ObservedObject var model: SessionFeedModel

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
                if model.isCold { wake }
                feed
                if let activity = model.activity {
                    activityLine(activity)
                }
                if let final = model.final {
                    footer(final)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 320)
    }

    // MARK: header

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    statusDot(ctx.date)
                    Text(model.title ?? "session")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(clock(ctx.date))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary.opacity(0.65))
                }
                HStack(spacing: 6) {
                    if let cwd = model.cwd { chip("folder", tidyPath(cwd)) }
                    if let branch = model.gitBranch { chip("arrow.triangle.branch", branch) }
                    if let m = model.model { chip("cpu", shortModel(m)) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private enum Status { case queued, working, done, failed, live, idle, cold, awaiting, attention }

    private func status(_ now: Date) -> Status {
        if let m = model.minion {
            switch m.status {
            case "done": return .done
            case "failed": return .failed
            case "queued": return .queued
            default: return .working
            }
        }
        // a live session knows its own state — no clock guessing required
        if let live = model.liveStatus {
            if model.isCold { return .cold }
            switch live {
            case .working: return .working
            case .awaitingInput: return .awaiting
            case .needsAttention: return .attention
            case .error: return .failed
            case .done: return .idle
            }
        }
        guard let last = model.lastActivity else { return .idle }
        return now.timeIntervalSince(last) < 90 ? .live : .idle
    }

    @ViewBuilder
    private func statusDot(_ now: Date) -> some View {
        switch status(now) {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.85))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
        case .queued:
            Circle()
                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 7, height: 7)
        case .working:
            PulseDot(color: .accentColor)
        case .live:
            PulseDot(color: .green)
        case .idle:
            Circle()
                .fill(.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
        case .cold:
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary.opacity(0.5))
        case .awaiting:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow.opacity(0.8))
        case .attention:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange.opacity(0.85))
        }
    }

    private func clock(_ now: Date) -> String {
        if let m = model.minion {
            guard let start = m.startedAt else { return "queued" }
            return Self.duration((m.finishedAt ?? now).timeIntervalSince(start))
        }
        guard let last = model.lastActivity else { return "" }
        let gap = now.timeIntervalSince(last)
        return gap < 4 ? "streaming" : "\(Self.duration(gap)) ago"
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
            Text(text)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary.opacity(0.7))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background { Capsule().fill(.white.opacity(0.06)) }
    }

    private func tidyPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func shortModel(_ m: String) -> String {
        m.hasPrefix("claude-") ? String(m.dropFirst("claude-".count)) : m
    }

    // MARK: cold + activity

    /// A restored tab that has never been woken has no process and no events —
    /// without this the panel is just an empty box. One click starts it; the
    /// transcript it already carries stays on screen underneath.
    private var wake: some View {
        Button { model.wake() } label: {
            HStack(spacing: 7) {
                Image(systemName: "power")
                    .font(.system(size: 10, weight: .semibold))
                Text("cold — click to wake")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background { RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)) }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    /// What the session's hands are doing right now ("reading Foo.swift").
    /// Pinned below the feed rather than scrolling with it — it's status, not
    /// history, and it's the line you open a panel to see.
    private func activityLine(_ text: String) -> some View {
        HStack(spacing: 7) {
            PulseDot(color: .accentColor)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: feed

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if model.events.isEmpty, !model.isCold {
                        Text(model.isLive ? "nothing said yet…" : "waiting for the first event…")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    ForEach(model.events) { ev in
                        row(ev).id(ev.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.events.count) {
                guard let last = model.events.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = model.events.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func row(_ ev: FeedEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: ev.symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint(ev.kind).opacity(0.75))
                .frame(width: 14)
            Text(ev.text)
                .font(.system(size: 11, weight: ev.kind == .prompt ? .medium : .regular, design: .rounded))
                .foregroundStyle(textColor(ev.kind))
                .italic(ev.kind == .thought)
                .lineLimit(ev.kind == .prompt || ev.kind == .thought ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tint(_ kind: FeedEvent.Kind) -> Color {
        switch kind {
        case .prompt: return .accentColor
        case .thought: return .accentColor
        case .action: return .secondary
        case .output: return .secondary
        }
    }

    private func textColor(_ kind: FeedEvent.Kind) -> Color {
        switch kind {
        case .prompt: return .primary.opacity(0.9)
        case .thought: return .primary.opacity(0.82)
        case .action: return .secondary.opacity(0.8)
        case .output: return .secondary.opacity(0.55)
        }
    }

    // MARK: footer

    private func footer(_ final: FeedFinal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            if let text = final.resultText {
                Text(text)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                stat(final.isError ? "xmark.circle.fill" : "checkmark.circle.fill",
                     final.isError ? "failed" : "done",
                     final.isError ? .red : .green)
                if let ms = final.durationMs { stat("clock", Self.duration(Double(ms) / 1000), .secondary) }
                if let cost = final.costUSD { stat("dollarsign.circle", costText(cost), .secondary) }
                if let turns = final.numTurns { stat("arrow.2.squarepath", "\(turns) turns", .secondary) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func stat(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
        }
    }

    private func costText(_ c: Double) -> String {
        c < 0.1 ? String(format: "$%.3f", c) : String(format: "$%.2f", c)
    }

    private static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
