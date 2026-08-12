import SwiftUI

/// The strip of little agent cards along the bottom of the window — bob's own
/// work-session tabs, the "+" that opens more, his minions, and any external
/// claude code sessions running in terminal tabs (idle ones folded behind a
/// small disclosure). The row sits centered while it's narrower than the
/// window and scrolls sideways once it outgrows it. Hover lifts a card (the
/// HoverTile spring); click floats its live panel — except tabs, where click
/// means "make it the stage".
struct MinionStrip: View {
    let minions: [MinionService.Minion]
    let sessions: [SessionWatcher.Session]
    var parked: [SessionWatcher.Session] = []
    var workSessions: [ClaudeSession] = []
    var activeID: UUID? = nil
    var onNewSession: () -> Void = {}

    @State private var showParked = false

    var body: some View {
        // The width has to come from a reader: inside a horizontal ScrollView the
        // scroll axis is proposed as unspecified, so `maxWidth: .infinity` on the
        // row would collapse to the cards instead of centering them.
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(workSessions) { session in
                        SessionTab(session: session, isActive: session.id == activeID)
                    }
                    NewSessionButton(action: onNewSession)
                    ForEach(minions) { MinionCard(minion: $0) }
                    ForEach(sessions) { SessionCard(session: $0) }
                    if !parked.isEmpty {
                        ParkedDisclosure(count: parked.count, open: $showParked)
                        if showParked {
                            ForEach(parked) { SessionCard(session: $0, dimmed: true) }
                        }
                    }
                }
                // vertical slack so a hovered card's lift and shadow aren't
                // shaved off by the scroll view's clip
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
                .frame(minWidth: geo.size.width, alignment: .center)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: showParked)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - work-session tabs

/// One of bob's own work sessions — a living claude in a project directory,
/// rendered center-stage when active. Observes the session directly: status
/// derives from its per-session @Published state, so the dot can never go
/// stale behind a manager-level snapshot. Click activates (waking a cold
/// restored tab); hover reveals peek (float a live panel without switching)
/// and ✕ (close).
struct SessionTab: View {
    @ObservedObject var session: ClaudeSession
    let isActive: Bool
    @State private var hover = false

    private var status: SessionStatus { SessionManager.status(of: session) }

    var body: some View {
        // not a Button: peek/✕ live inside, and a nested Button's click can
        // bleed into its host's action. A tap gesture yields to child buttons.
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(session.config.name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(isActive ? 0.95 : 0.85))
                    .lineLimit(1)
                Text(cwdTail)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 160, alignment: .leading)
            }
            if hover {
                peekButton
                closeButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
                .overlay {
                    if isActive {
                        Capsule(style: .continuous).fill(Color.accentColor.opacity(0.10))
                    }
                }
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    isActive ? Color.accentColor.opacity(0.45) : Color.white.opacity(hover ? 0.18 : 0.06),
                    lineWidth: isActive ? 1 : 0.5
                )
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            // activate, never activeID directly — a cold restored tab only
            // spawns through this door
            SessionManager.shared.activate(session.id)
        }
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 7, x: 0, y: 3)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
        .contextMenu {
            Button("peek live panel") { peek() }
            Button("close session") { SessionManager.shared.close(session.id) }
        }
        .help(isActive ? "this session is on stage" : "switch to \(session.config.name)")
    }

    /// "~/Code/lootgo" — where this claude lives, home-abbreviated.
    private var cwdTail: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.config.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Glance without switching — floats the session's live panel (P2c).
    private func peek() {
        SessionPanelController.shared.toggleLive(session: session)
    }

    private var peekButton: some View {
        Button { peek() } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help("peek without switching")
        .transition(.opacity)
    }

    private var closeButton: some View {
        Button { SessionManager.shared.close(session.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help("close this session")
        .transition(.opacity)
    }

    /// The five words a tab can say at a glance: working (accent pulse),
    /// awaiting input (amber), needs attention (red), done (dim), session
    /// down (hollow red).
    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .working:
            PulseDot(color: .accentColor)
        case .awaitingInput:
            Circle().fill(.orange.opacity(0.9)).frame(width: 7, height: 7)
        case .needsAttention:
            Circle().fill(.red.opacity(0.85)).frame(width: 7, height: 7)
        case .done:
            Circle().fill(.secondary.opacity(0.35)).frame(width: 7, height: 7)
        case .error:
            Circle().strokeBorder(.red.opacity(0.8), lineWidth: 1.4).frame(width: 7, height: 7)
        }
    }
}

/// The small "+" beside the tabs — opens the project picker overlay
/// (ContentView owns the picker; this only rings the bell).
struct NewSessionButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(hover ? 0.9 : 0.55))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background { Circle().fill(.ultraThinMaterial) }
        .overlay { Circle().stroke(Color.white.opacity(hover ? 0.18 : 0.06), lineWidth: 0.5) }
        .scaleEffect(hover ? 1.06 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
        .help("new work session")
    }
}

// MARK: - the project picker

/// The compact "+" picker — every project ProjectScanner knows under ~/Code
/// (read-only reuse), filter-as-you-type, Enter or click opens a session
/// there. A "current repo" shortcut pins the busiest external terminal's cwd
/// to the top when there is one.
///
/// Esc closes just the picker: its field owns focus while it's up, so the
/// press lands here and never reaches CenterStage's layer-peeling; if the
/// owner clicks back into the main input first, CenterStage's interceptHide
/// (wired by ContentView) still closes the picker before any app-hide.
struct ProjectPicker: View {
    var currentRepo: URL? = nil
    let onPick: (URL) -> Void
    let onClose: () -> Void

    struct Row: Identifiable {
        let name: String
        let url: URL
        var pinned = false
        var id: String { (pinned ? "current-" : "") + url.path }
    }

    @State private var query = ""
    @State private var projects: [Row] = []
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var matches: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var rows: [Row] = []
        if let current = currentRepo {
            let name = current.lastPathComponent
            if q.isEmpty || name.localizedCaseInsensitiveContains(q) {
                rows.append(Row(name: name, url: current, pinned: true))
            }
        }
        rows += projects.filter { row in
            guard row.url.standardizedFileURL != currentRepo?.standardizedFileURL else { return false }
            return q.isEmpty || row.name.localizedCaseInsensitiveContains(q)
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                "",
                text: $query,
                prompt: Text("open a project…").foregroundStyle(.secondary.opacity(0.55))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .focused($focused)
            .onSubmit { if let first = matches.first { onPick(first.url) } }
            .onKeyPress(.escape) {
                onClose()
                return .handled
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !loaded {
                        hint("scanning ~/Code…")
                    } else if matches.isEmpty {
                        hint("nothing matches")
                    }
                    ForEach(matches) { row in
                        PickerRow(row: row) { onPick(row.url) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 340)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial) }
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.32), radius: 18, x: 0, y: 6)
        .onExitCommand { onClose() }
        .onAppear { focused = true }
        .task {
            // ProjectScanner already knows how ~/Code and claude's history map
            // onto each other — reuse it read-only; only spawnable dirs listed.
            let scanner = ProjectScanner(home: FileManager.default.homeDirectoryForCurrentUser)
            let scanned = await scanner.scan()
            projects = scanned.compactMap { project in
                project.realPath.map { Row(name: project.name, url: $0) }
            }
            loaded = true
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary.opacity(0.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}

private struct PickerRow: View {
    let row: ProjectPicker.Row
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: row.pinned ? "scope" : "folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(row.pinned ? Color.accentColor.opacity(0.8) : .secondary.opacity(0.55))
                    .frame(width: 14)
                Text(row.pinned ? "current — \(row.name)" : row.name)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(tidyPath)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.08 : 0))
        }
        .onHover { hover = $0 }
    }

    private var tidyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = row.url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - minion cards

struct MinionCard: View {
    let minion: MinionService.Minion
    @ObservedObject private var service = MinionService.shared
    @State private var hover = false

    private var events: [MinionService.Event] { service.events(for: minion.id) }

    var body: some View {
        Button {
            SessionPanelController.shared.toggle(.minion(minion))
        } label: {
            HStack(spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(minion.task)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    subtitle
                }
                if hover {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
        .overlay { Capsule(style: .continuous).stroke(Color.white.opacity(hover ? 0.18 : 0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 7, x: 0, y: 3)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if minion.status == "working" {
            if let latest = events.last(where: { !$0.isThought }) ?? events.last {
                // show what the minion is doing RIGHT NOW
                Text(latest.text)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let start = minion.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("working · \(elapsed(from: start, to: ctx.date))")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
        } else if let detail = minion.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    @ViewBuilder
    private var statusDot: some View {
        switch minion.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.85))
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
        case "queued":
            Circle()
                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 7, height: 7)
        default: // working
            PulseDot(color: .accentColor)
        }
    }
}

// MARK: - external terminal sessions

/// An external claude code session — someone else's hands, running in a
/// terminal tab. Same capsule as a minion card, marked with a terminal glyph;
/// the dot speaks the registry's word (busy green, waiting amber, idle dim —
/// unknown stays the old green pulse). Parked (idle) cards render dimmed
/// behind the disclosure.
struct SessionCard: View {
    let session: SessionWatcher.Session
    var dimmed: Bool = false
    @State private var hover = false

    var body: some View {
        Button {
            SessionPanelController.shared.toggle(.external(session))
        } label: {
            HStack(spacing: 8) {
                statusDot
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    if let title = session.title {
                        Text(title)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                if hover {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
        .overlay { Capsule(style: .continuous).stroke(Color.white.opacity(hover ? 0.18 : 0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 7, x: 0, y: 3)
        .opacity(dimmed && !hover ? 0.6 : 1)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch session.status {
        case .busy:
            PulseDot(color: .green)
        case .waiting:
            Circle().fill(.orange.opacity(0.9)).frame(width: 7, height: 7)
        case .idle:
            Circle().fill(.secondary.opacity(0.4)).frame(width: 7, height: 7)
        case .unknown:
            // transcript-live with no registry record — the pre-registry look
            PulseDot(color: .green)
        }
    }
}

/// "3 idle" — the parked externals, counted instead of crowding the band.
/// Click to unfold them (dimmed), click again to tuck them away.
struct ParkedDisclosure: View {
    let count: Int
    @Binding var open: Bool
    @State private var hover = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("\(count) idle")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
        .overlay { Capsule(style: .continuous).stroke(Color.white.opacity(hover ? 0.14 : 0.05), lineWidth: 0.5) }
        .opacity(hover ? 1 : 0.75)
        .onHover { hover = $0 }
        .help(open ? "tuck idle sessions away" : "\(count) idle terminal session\(count == 1 ? "" : "s")")
    }
}

/// The little breathing dot that means "alive right now".
struct PulseDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.9))
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.0 : 0.5)
            .opacity(pulse ? 1.0 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
