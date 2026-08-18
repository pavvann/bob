import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = ClaudeBridge()
    @StateObject private var voiceIn = VoiceInput()
    @StateObject private var voiceOut = VoiceOutput()
    @ObservedObject private var home = BobHome.shared

    @ObservedObject private var minions = MinionService.shared
    @ObservedObject private var sessions = SessionWatcher.shared
    @ObservedObject private var music = MusicService.shared
    @ObservedObject private var sessionManager = SessionManager.shared
    @State private var showMemory = false
    @State private var showProjectPicker = false
    @ObservedObject private var resume = ResumeStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // album-art vibe — washes the window with the current track's colors
            AmbientBackground(palette: music.palette, active: music.isPlaying)

            HStack(spacing: 14) {
                VStack(spacing: 18) {
                    // ambient context — glanceable strip across the top.
                    // hover any tile to grow it (dock-style) into the richer
                    // expanded variant. HStack alignment top so smaller tiles
                    // sit at the top while the hovered one expands downward.
                    // Full tiles on bob's own stage; on a session page they
                    // collapse to icons and give the transcript the height back.
                    // Leading-aligned when collapsed so the row reads as a small
                    // strip of controls rather than five lonely dots spread wide.
                    HStack(alignment: .top, spacing: ambientCollapsed ? 8 : 12) {
                        HoverTile(title: "work", iconified: ambientCollapsed) { exp in WorkTileContent(expanded: exp) }
                        HoverTile(title: "music", iconified: ambientCollapsed) { exp in MusicTileContent(expanded: exp) }
                        HoverTile(title: "todos", iconified: ambientCollapsed) { exp in TodoTileContent(expanded: exp) }
                        HoverTile(title: "calendar", iconified: ambientCollapsed) { exp in CalendarTileContent(expanded: exp) }
                        HoverTile(title: "weather", iconified: ambientCollapsed) { exp in WeatherTileContent(expanded: exp) }
                        if ambientCollapsed { Spacer(minLength: 0) }
                    }
                    .frame(height: ambientCollapsed ? 30 : 110, alignment: .top)
                    .animation(.spring(response: 0.34, dampingFraction: 0.84), value: ambientCollapsed)
                    .zIndex(2)

                    // bob — the conductor, centered in everything the tiles and
                    // the minion band leave behind. The greedy frame is what
                    // pins the band to the window's bottom edge.
                    // The stage keeps the middle; the rail takes the right
                    // gutter when a work session is on it. A ghost of the same
                    // width holds the left gutter, so the conversation stays
                    // centred whether or not the rail is there — a stage that
                    // slid sideways every time you changed tabs would be worse
                    // than no rail at all.
                    // Gutters only when the window can spare them: the first
                    // arrangement declares a minimum for the stage, so a narrow
                    // window falls through to the second and the conversation
                    // keeps its full column instead of being squeezed to make
                    // room for chrome.
                    ViewThatFits(in: .horizontal) {
                        stageRow(withGutters: true)
                        stageRow(withGutters: false)
                    }
                    .frame(maxHeight: .infinity)
                    .animation(.easeInOut(duration: 0.2), value: activeSession?.id)

                    minionBand
                }
                .frame(maxWidth: .infinity)

                if showMemory {
                    Tile(title: "memory") { MemoryTileContent() }
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: minions.active)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: sessions.live)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: sessions.parked)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: sessionManager.workSessions.map(\.id))
            .animation(.easeInOut(duration: 0.2), value: sessionManager.activeID)

            memoryToggle
            projectPickerOverlay
            resumePickerOverlay
        }
        .task {
            await home.bootstrapIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: MinionService.minionFinished)) { note in
            // a hand reported back — let bob relay it in his own voice
            guard let info = note.userInfo,
                  let task = info["task"] as? String else { return }
            let detail = info["detail"] as? String ?? ""
            let ok = info["ok"] as? Bool ?? true
            bridge.enqueueDebrief(task: task, detail: detail, ok: ok)
        }
    }

    /// The bottom band: bob's own work-session tabs (click to take the stage),
    /// the "+" that opens more, minions he's delegated to, and live claude
    /// code sessions running in terminal tabs — click any card to float its
    /// live panel; idle terminals fold behind a count. Its height is held
    /// whether or not anything is running, so a hand arriving never shoves the
    /// input bar upward. Always rendered now: the "+" is how the first work
    /// session is born.
    private var minionBand: some View {
        MinionStrip(
            minions: minions.active,
            sessions: sessions.live,
            parked: sessions.parked,
            workSessions: sessionManager.workSessions,
            activeID: sessionManager.activeID,
            onNewSession: {
                withAnimation(.easeOut(duration: 0.18)) { showProjectPicker.toggle() }
            }
        )
        .frame(height: 62)
        .frame(maxWidth: .infinity)
    }

    // MARK: the "+" project picker

    /// Floats just above the band (it lives at this level, not in CenterStage,
    /// so tabs and picker share one owner). A whisper-thin scrim makes any
    /// outside click a dismissal; esc closes it from inside (the picker's own
    /// field holds focus) or via CenterStage's interceptHide when the main
    /// input has focus instead.
    @ViewBuilder
    private var projectPickerOverlay: some View {
        if showProjectPicker {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { closeProjectPicker() }
                .zIndex(3)
            ProjectPicker(
                currentRepo: currentRepo,
                onPick: { url, permissions, model in
                    withAnimation(.easeOut(duration: 0.18)) { showProjectPicker = false }
                    // spawn (idempotent per cwd — a cold restored tab wakes
                    // instead of forking), then activate: spawnWorkSession
                    // deliberately doesn't touch activeID itself. The picker's
                    // ask-first hand and model dial ride along.
                    let session = sessionManager.spawnWorkSession(cwd: url, model: model, permissions: permissions)
                    SurfaceRouter.shared.close()   // picking = "put it on stage"
                    sessionManager.activate(session.id)
                },
                onClose: { closeProjectPicker() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 88)
            .zIndex(4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// `/resume`'s list, floating in the same place the project picker does —
    /// they're the same gesture (pick a thing, put it on stage), so they get the
    /// same geometry, scrim, and dismissal.
    @ViewBuilder
    private var resumePickerOverlay: some View {
        if resume.isOpen {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { closeResumePicker() }
                .zIndex(3)
            ResumePicker()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 88)
                .zIndex(4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func closeResumePicker() {
        withAnimation(.easeOut(duration: 0.18)) { resume.close() }
        NotificationCenter.default.post(name: HotKeyManager.didSummon, object: nil)
    }

    /// The stage, optionally flanked: a ghost holding the left gutter so the
    /// conversation stays centred, and the rail on the right when a work session
    /// is on stage. `minWidth` is what makes ViewThatFits able to say no.
    @ViewBuilder
    private func stageRow(withGutters: Bool) -> some View {
        // Four equal flexible spacers: the tree and the rail float in the
        // middle of their own gutters rather than hugging either the
        // conversation or the window edge, and the stage stays centred because
        // both gutters are the same width.
        HStack(alignment: .top, spacing: 0) {
            if withGutters {
                Spacer(minLength: 10)
                if let staged = activeSession, staged.id != sessionManager.companionID {
                    FileTree(root: staged.config.cwd)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    Color.clear.frame(width: FileTree.width, height: 1)
                }
                Spacer(minLength: 10)
            }
            CenterStage(
                bridge: bridge, voiceIn: voiceIn, voiceOut: voiceOut, home: home,
                interceptHide: {
                    // each picker is one more esc layer, peeled before
                    // app-hide — esc can never hide bob while one is up
                    if resume.isOpen {
                        closeResumePicker()
                        return true
                    }
                    guard showProjectPicker else { return false }
                    closeProjectPicker()
                    return true
                }
            )
            .frame(minWidth: withGutters ? 560 : nil, maxWidth: 640)
            .frame(maxHeight: .infinity)
            if withGutters {
                Spacer(minLength: 10)
                if let staged = activeSession {
                    SessionRail(session: staged)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    Color.clear.frame(width: SessionRail.width, height: 1)
                }
                Spacer(minLength: 10)
            }
        }
    }

    /// A session or a surface is on stage, so the ambient tiles step aside. Bob's
    /// own thread keeps them: there, they *are* the point.
    private var ambientCollapsed: Bool {
        SurfaceRouter.shared.active != nil
            || (sessionManager.activeID != nil && sessionManager.activeID != sessionManager.companionID)
    }

    /// Whichever session is on stage — bob's own thread included. Bob can be
    /// asked a question too, and now that every session spawns able to relay one,
    /// a companion question with nowhere to appear would hang the turn forever.
    /// The rail's cards are individually conditional, so bob simply shows fewer
    /// of them (no branch: ~/bob keeps no git).
    private var activeSession: ClaudeSession? {
        guard SurfaceRouter.shared.active == nil, let id = sessionManager.activeID else { return nil }
        return sessionManager.sessions.first { $0.id == id }
    }

    private func closeProjectPicker() {
        withAnimation(.easeOut(duration: 0.18)) { showProjectPicker = false }
        // hand the cursor back to the stage's input box — same signal ⌥Space
        // sends, same listener catches it
        NotificationCenter.default.post(name: HotKeyManager.didSummon, object: nil)
    }

    /// The repo the owner is most likely "in" right now — the busiest external
    /// terminal session's cwd, for the picker's pinned shortcut. Absent when
    /// nothing external is running.
    private var currentRepo: URL? {
        let ranked = sessions.live.sorted { $0.status > $1.status }
        guard let cwd = ranked.first(where: { $0.status >= .waiting })?.cwd ?? ranked.first?.cwd
        else { return nil }
        return URL(fileURLWithPath: cwd)
    }

    private var memoryToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showMemory.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showMemory ? Color.accentColor.opacity(0.85) : .secondary.opacity(0.55))
                .padding(7)
                .background { Circle().fill(.ultraThinMaterial) }
        }
        .buttonStyle(.plain)
        .help(showMemory ? "hide memory" : "show memory")
        .padding(.top, 12)
        .padding(.trailing, 14)
    }
}

// MARK: tile contents

private struct PlaceholderTileContent: View {
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(primary)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.72))
            Text(secondary)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.45))
            Spacer(minLength: 0)
        }
    }
}

private struct WorkTileContent: View {
    var expanded: Bool = false
    @ObservedObject private var service = GitHubService.shared

    private enum Section: Hashable {
        case reviewRequests
        case openPRs
    }

    @State private var expandedSection: Section?

    var body: some View {
        if let state = service.state {
            if !state.ghAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    Text("github not connected")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.75))
                    if let err = state.lastError {
                        Text(err)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            } else if isAllClear(state) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("all clear")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("no PRs to review, no unread notifications.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.45))
                    Spacer(minLength: 0)
                }
            } else if expanded {
                expandedView(state: state)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.reviewRequests.isEmpty {
                            expandableRow(
                                section: .reviewRequests,
                                icon: "eye",
                                tint: .blue,
                                count: state.reviewRequests.count,
                                singular: "PR awaiting your review",
                                plural: "PRs awaiting your review",
                                prs: state.reviewRequests
                            )
                        }
                        if !state.openPRs.isEmpty {
                            expandableRow(
                                section: .openPRs,
                                icon: "arrow.triangle.pull",
                                tint: .green,
                                count: state.openPRs.count,
                                singular: "PR of yours open",
                                plural: "PRs of yours open",
                                prs: state.openPRs
                            )
                        }
                        if state.unreadNotifications > 0 {
                            Button {
                                if let url = URL(string: "https://github.com/notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                rowLabel(
                                    icon: "bell",
                                    tint: .orange,
                                    count: state.unreadNotifications,
                                    text: state.unreadNotifications == 1 ? "unread notification" : "unread notifications",
                                    chevron: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .scrollIndicators(.never)
            }
        } else {
            Text("loading...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    private func isAllClear(_ s: GitHubService.State) -> Bool {
        s.reviewRequests.isEmpty && s.openPRs.isEmpty && s.unreadNotifications == 0
    }

    /// Hover-expanded view: flat list of every open PR with title + repo,
    /// plus the unread-notifications link. No dropdowns — everything visible.
    private func expandedView(state: GitHubService.State) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !state.reviewRequests.isEmpty {
                    sectionHeader("awaiting your review", icon: "eye", tint: .blue, count: state.reviewRequests.count)
                    ForEach(state.reviewRequests) { pr in prRow(pr) }
                }
                if !state.openPRs.isEmpty {
                    sectionHeader("your open PRs", icon: "arrow.triangle.pull", tint: .green, count: state.openPRs.count)
                        .padding(.top, state.reviewRequests.isEmpty ? 0 : 4)
                    ForEach(state.openPRs) { pr in prRow(pr) }
                }
                if state.unreadNotifications > 0 {
                    Button {
                        if let url = URL(string: "https://github.com/notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bell")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange.opacity(0.85))
                            Text("\(state.unreadNotifications) unread")
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary.opacity(0.85))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary.opacity(0.55))
                        }
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .scrollIndicators(.never)
    }

    private func sectionHeader(_ text: String, icon: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
            Text("\(count) \(text)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
        }
    }

    private func prRow(_ pr: GitHubService.PR) -> some View {
        Button {
            if let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(0.55))
                Text(pr.title)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(pr.repo)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.leading, 12)
        }
        .buttonStyle(.plain)
    }

    private func expandableRow(
        section: Section,
        icon: String,
        tint: Color,
        count: Int,
        singular: String,
        plural: String,
        prs: [GitHubService.PR]
    ) -> some View {
        let isOpen = expandedSection == section
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    expandedSection = isOpen ? nil : section
                }
            } label: {
                rowLabel(
                    icon: icon,
                    tint: tint,
                    count: count,
                    text: count == 1 ? singular : plural,
                    chevron: isOpen ? "chevron.up" : "chevron.down"
                )
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(prs) { pr in
                        Button {
                            if let url = URL(string: pr.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                Text(pr.title)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.88))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(pr.repo)
                                    .font(.system(size: 9, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 2)
            }
        }
    }

    private func rowLabel(icon: String, tint: Color, count: Int, text: String, chevron: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 14)
            (Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.9))
             + Text(" \(text)")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
            )
                .lineLimit(1)
            Spacer()
            Image(systemName: chevron)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

private struct TodoTileContent: View {
    var expanded: Bool = false
    @ObservedObject private var service = TodoService.shared

    var body: some View {
        let open = service.open
        let visible = expanded ? Array(open) : Array(open.prefix(4))
        VStack(alignment: .leading, spacing: 5) {
            if open.isEmpty {
                Text(service.todos.isEmpty ? "no todos." : "all done.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.65))
                Text("ask bob to add one.")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.45))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(visible) { todo in
                            HStack(spacing: 7) {
                                Button {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        service.toggle(todo.id)
                                    }
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary.opacity(0.65))
                                }
                                .buttonStyle(.plain)
                                Text(todo.text)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .lineLimit(expanded ? 2 : 1)
                                    .truncationMode(.tail)
                            }
                        }
                        if !expanded && open.count > 4 {
                            Text("+\(open.count - 4) more")
                                .font(.system(size: 9, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary.opacity(0.5))
                                .padding(.leading, 18)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WeatherTileContent: View {
    var expanded: Bool = false
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        switch service.locationStatus {
        case .notDetermined:
            connectView
        case .denied, .restricted:
            deniedView
        default:
            // .authorized / .authorizedAlways on macOS
            authorizedView
        }
    }

    private var connectView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                service.requestAccess()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 11))
                    Text("connect location")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.blue.opacity(0.9))
            }
            .buttonStyle(.plain)
            Text("local weather, updated through the day.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var deniedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("location access denied")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("enable in system settings →")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var authorizedView: some View {
        if let s = service.state {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: s.symbolName)
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(s.temperatureC.rounded()))°")
                        .font(.system(size: 26, weight: .light, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text(s.condition)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                    if let high = s.highC, let low = s.lowC {
                        Text("H:\(Int(high.rounded()))°  L:\(Int(low.rounded()))°")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    Text(s.locationName)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else if let err = service.lastError {
            VStack(alignment: .leading, spacing: 4) {
                Text(err)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            Text("loading weather...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

private struct CalendarTileContent: View {
    var expanded: Bool = false
    @ObservedObject private var service = CalendarService.shared

    var body: some View {
        switch service.authorization {
        case .notDetermined, .unknown:
            unauthorizedConnectView
        case .denied, .restricted:
            deniedView
        case .fullAccess, .writeOnly:
            authorizedView
        }
    }

    private var unauthorizedConnectView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await service.requestAccess() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11))
                    Text("connect calendar")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.blue.opacity(0.9))
            }
            .buttonStyle(.plain)
            Text("show next event + join link for in-progress meetings.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var deniedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("calendar access denied")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("enable in system settings →")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var authorizedView: some View {
        if let state = service.state {
            if expanded {
                expandedEventsView(state: state)
            } else if let now = state.now {
                eventCard(event: now, isInProgress: true)
            } else if let next = state.next {
                eventCard(event: next, isInProgress: false)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("nothing scheduled")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("you're clear for the next 7 days.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text("loading...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    /// Hover-expanded calendar: show current + next event when both exist.
    @ViewBuilder
    private func expandedEventsView(state: CalendarService.State) -> some View {
        if state.now == nil && state.next == nil {
            VStack(alignment: .leading, spacing: 3) {
                Text("nothing scheduled")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text("you're clear for the next 7 days.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let now = state.now {
                    eventCard(event: now, isInProgress: true)
                }
                if let next = state.next {
                    eventCard(event: next, isInProgress: false)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func eventCard(event: CalendarService.Event, isInProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isInProgress {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 7, height: 7)
                }
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(timingText(event: event, isInProgress: isInProgress))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
            if !event.calendarTitle.isEmpty {
                Text(event.calendarTitle)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            if let conference = event.conferenceURL, let url = URL(string: conference) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9))
                        Text("join")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.blue.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(.blue.opacity(0.12))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func timingText(event: CalendarService.Event, isInProgress: Bool) -> String {
        if isInProgress {
            return "ends \(humanInterval(from: Date(), to: event.endDate))"
        } else {
            return "starts \(humanInterval(from: Date(), to: event.startDate)) · \(absoluteTime(event.startDate))"
        }
    }

    /// "in 12m" / "in 1h 5m" / "in 2d 3h" etc.
    private func humanInterval(from start: Date, to end: Date) -> String {
        let interval = max(0, end.timeIntervalSince(start))
        if interval < 60 { return "now" }
        if interval < 3600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            let mins = Int((interval - Double(hours) * 3600) / 60)
            return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
        }
        let days = Int(interval / 86400)
        let hours = Int((interval - Double(days) * 86400) / 3600)
        return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
    }

    private func absoluteTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            let f = DateFormatter(); f.dateFormat = "'tomorrow,' h:mm a"
            return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return f.string(from: date)
    }
}

private struct MusicTileContent: View {
    var expanded: Bool = false
    @ObservedObject private var service = MusicService.shared

    var body: some View {
        if let playback = service.current, let track = playback.track {
            HStack(alignment: .top, spacing: 12) {
                artwork(url: track.artworkURL)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: expanded ? 14 : 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(expanded ? 3 : 2)
                    Text(track.artist)
                        .font(.system(size: expanded ? 12 : 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(expanded ? 2 : 1)
                    if expanded, !track.album.isEmpty {
                        Text(track.album)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                    if playback.state != "playing" {
                        Text(playback.state)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .textCase(.uppercase)
                            .tracking(0.7)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("nothing playing")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text("ask bob to play something.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
    }

    private var artworkSize: CGFloat { expanded ? 110 : 56 }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholderArt
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholderArt
                .frame(width: artworkSize, height: artworkSize)
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.secondary.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
    }
}

private struct MemoryTileContent: View {
    @State private var entries: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !loaded {
                EmptyView()
            } else if entries.isEmpty {
                Text("nothing here yet.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
            } else {
                ForEach(Array(entries.prefix(4).enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            entries = Self.loadEntries()
            loaded = true
        }
    }

    /// Parses bullets under the `## entries` heading of `~/bob/MEMORY.md`.
    private static func loadEntries() -> [String] {
        let path = BobHome.shared.root.appendingPathComponent("MEMORY.md")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var result: [String] = []
        var inEntries = false
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") {
                inEntries = line.localizedCaseInsensitiveContains("entries")
                continue
            }
            if inEntries {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    result.append(String(trimmed.dropFirst(2)))
                }
            }
        }
        return result.reversed()
    }
}
