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
    var tabs: [SessionRef] = []
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
                    // the way home sits first, then the two always-present
                    // surfaces — notes and canvas — before anything that comes
                    // and goes
                    HomeChip()
                    ForEach(AppSurface.allCases) { surface in
                        SurfaceChip(surface: surface)
                    }
                    ForEach(tabs) { tab in
                        // one switch, one generic chip: the provider changes the
                        // glyph and the status reading, never the furniture
                        switch tab {
                        case .claude(let session):
                            SessionTab(session: session, isActive: session.id == activeID)
                        case .codex(let session):
                            SessionTab(session: session, isActive: session.id == activeID)
                        }
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

// MARK: - the way home

/// Bob has no tab of his own — the strip renders `workSessions`, which filters
/// him out — so before this chip existed there was nothing to click to get back
/// to the conversation from a session or a surface. It leads the band, lights up
/// when bob already holds the stage, and is the same gesture as ⌘0 and the last
/// esc layer.
struct HomeChip: View {
    @ObservedObject private var manager = SessionManager.shared
    @ObservedObject private var router = SurfaceRouter.shared
    @State private var hover = false

    private var isHome: Bool { router.active == nil && manager.activeID == manager.companionID }

    var body: some View {
        // nothing to go home to in compatibility mode (no companion session)
        if manager.companionID != nil {
            Button { manager.goHome() } label: {
                Image(systemName: "house")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHome ? Color.accentColor.opacity(0.9)
                                            : .secondary.opacity(hover ? 0.9 : 0.55))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background {
                Circle().fill(.ultraThinMaterial)
                    .overlay { if isHome { Circle().fill(Color.accentColor.opacity(0.10)) } }
            }
            .overlay {
                Circle().stroke(
                    isHome ? Color.accentColor.opacity(0.45) : .white.opacity(hover ? 0.18 : 0.06),
                    lineWidth: isHome ? 1 : 0.5)
            }
            .scaleEffect(hover ? 1.06 : 1)
            .onHover { isHover in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
            }
            .help(isHome ? "bob's already on stage" : "back to bob (⌘B)")
        }
    }
}

// MARK: - surface chips

/// One of the two fixed chips at the band's leading edge — notes and canvas,
/// always present, never scrolling away behind session cards. Click puts that
/// surface on the center stage; click again drops back to the conversation.
/// Active styling mirrors an active session tab (accent wash + stroke), so
/// "what's on stage" reads the same across chips and tabs.
struct SurfaceChip: View {
    let surface: AppSurface
    @ObservedObject private var router = SurfaceRouter.shared
    @State private var hover = false

    private var isActive: Bool { router.active == surface }

    var body: some View {
        Button { router.toggle(surface) } label: {
            Image(systemName: surface.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor.opacity(0.9)
                                          : .secondary.opacity(hover ? 0.9 : 0.55))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle().fill(.ultraThinMaterial)
                .overlay { if isActive { Circle().fill(Color.accentColor.opacity(0.10)) } }
        }
        .overlay {
            Circle().stroke(
                isActive ? Color.accentColor.opacity(0.45) : .white.opacity(hover ? 0.18 : 0.06),
                lineWidth: isActive ? 1 : 0.5)
        }
        .scaleEffect(hover ? 1.06 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
        .help(isActive ? "back to the conversation" : "open \(surface.label)")
    }
}

// MARK: - work-session tabs

/// One of bob's own work sessions — a living claude or codex in a project
/// directory, rendered center-stage when active. Observes the session directly:
/// status derives from its per-session @Published state, so the dot can never go
/// stale behind a manager-level snapshot. Click activates (waking a cold
/// restored tab); hover reveals peek (float a live panel without switching)
/// and ✕ (close).
struct SessionTab<S: StageSession>: View {
    @ObservedObject var session: S
    let isActive: Bool
    @State private var hover = false
    @ObservedObject private var broker = UIPermissionBroker.shared

    private var status: SessionStatus {
        if let codex = session.codexSession { return SessionManager.status(of: codex) }
        if let claude = session.claudeSession { return SessionManager.status(of: claude) }
        return .done
    }
    /// The oldest tool call this session is holding for an answer, if any — an
    /// ask-first claude is stopped dead until this is settled.
    private var ask: PermissionRequest? { broker.ask(for: session.id) }
    /// A pill while it's a tab; a small panel while it's asking, because a
    /// capsule can't hold two lines and two buttons without looking silly.
    private var shape: AnyShape {
        ask == nil
            ? AnyShape(Capsule(style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var body: some View {
        // not a Button: peek/✕/allow/deny live inside, and a nested Button's
        // click can bleed into its host's action. A tap gesture yields to them.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        providerGlyph
                        Text(session.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(isActive ? 0.95 : 0.85))
                            .lineLimit(1)
                    }
                    Text(cwdTail)
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                if ask != nil { askBadge }
                if hover {
                    if session.claudeSession != nil { peekButton }
                    closeButton
                }
            }
            if let ask {
                PermissionAskCard(ask: ask, compact: true)
                    .frame(maxWidth: 236, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            shape.fill(.ultraThinMaterial)
                .overlay {
                    if ask != nil {
                        shape.fill(Color.orange.opacity(0.10))
                    } else if isActive {
                        shape.fill(Color.accentColor.opacity(0.10))
                    }
                }
        }
        .overlay {
            shape.stroke(strokeTint, lineWidth: ask != nil || isActive ? 1 : 0.5)
        }
        .contentShape(shape)
        .onTapGesture {
            // clicking a tab means "put this session on stage" — a surface
            // sitting over the stage would otherwise swallow the click silently
            SurfaceRouter.shared.close()
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
            if session.claudeSession != nil {
                Button("peek live panel") { peek() }
            }
            Button("close session") { SessionManager.shared.close(session.id) }
        }
        .help(isActive ? "this session is on stage" : "switch to \(session.displayName)")
    }

    private var strokeTint: Color {
        if ask != nil { return .orange.opacity(0.55) }
        if isActive { return .accentColor.opacity(0.45) }
        return .white.opacity(hover ? 0.18 : 0.06)
    }

    /// Which agent is behind this tab — a mark, not a label: the band is tight,
    /// and claude wears nothing because claude is what a tab is unless it says
    /// otherwise.
    @ViewBuilder
    private var providerGlyph: some View {
        if let glyph = session.provider.glyph {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.65))
                .help("a codex session")
        }
    }

    /// "waiting on you" at a glance, counted when more than one tool is queued
    /// behind the card.
    private var askBadge: some View {
        let count = broker.count(for: session.id)
        return HStack(spacing: 3) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 8, weight: .semibold))
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.orange.opacity(0.95))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background { Capsule().fill(.orange.opacity(0.16)) }
        .help(count > 1 ? "\(count) tool calls waiting on you" : "a tool call is waiting on you")
    }

    /// "~/Code/webapp" — where this session lives, home-abbreviated.
    private var cwdTail: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Glance without switching — floats the session's live panel (P2c). The
    /// panel reads claude's feed model, so a codex tab has nothing to float
    /// yet and the affordance is hidden rather than dead.
    private func peek() {
        guard let claude = session.claudeSession else { return }
        SessionPanelController.shared.toggleLive(session: claude)
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

// MARK: - ask-first approval

/// The safety affordance, not a dialog system: one tool call, the argument that
/// matters, two answers (three in a panel, where "always" earns its room). Amber
/// because it's attention rather than alarm — nothing is wrong, something is
/// waiting, and the claude on the other end is stopped until it isn't.
///
/// Drawn wherever the session is visible — on its tab and in any panel watching
/// it — all reading one broker, so answering in either place closes both.
struct PermissionAskCard: View {
    let ask: PermissionRequest
    /// Tab cards tighten the type and drop "always": a tab is the doorbell, a
    /// panel is where you read before deciding.
    var compact = false

    @ObservedObject private var broker = UIPermissionBroker.shared

    private var queued: Int { max(0, broker.count(for: ask.sessionId) - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 5) {
                Image(systemName: ask.symbol)
                    .font(.system(size: compact ? 9 : 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
                Text(ask.toolName)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if queued > 0 {
                    Text("+\(queued) waiting")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            Text(ask.detail)
                .font(.system(size: compact ? 9 : 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.9))
                .lineLimit(compact ? 1 : 3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if ask.choices.isEmpty {
                    answer("allow", filled: true) { broker.allow(ask) }
                    answer("deny") { broker.deny(ask) }
                    if !compact {
                        answer("always") { broker.allowAlways(ask) }
                            .help(ask.alwaysScope)
                    }
                } else {
                    // codex: the buttons ARE the request's `availableDecisions`,
                    // in its own order. The set differs per approval kind and
                    // drifts between versions — the live exec approval offered
                    // no `decline` at all — so nothing here may assume a shape.
                    ForEach(ask.choices) { choice in
                        answer(choice.label, filled: choice.tone == .affirm,
                               danger: choice.tone == .stop) { broker.choose(ask, choice) }
                            .help(choice.hint ?? choice.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 7 : 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.orange.opacity(0.30), lineWidth: 0.5)
        }
    }

    private func answer(_ title: String, filled: Bool = false, danger: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? .black.opacity(0.85)
                                        : (danger ? .red.opacity(0.9) : .primary.opacity(0.8)))
                .lineLimit(1)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 3 : 4)
                .background {
                    Capsule().fill(filled ? Color.orange.opacity(0.85) : Color.white.opacity(0.10))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
    /// Everything the pick decides travels in one value — which agent, which
    /// model, and whether its tools wait on you. The manager takes it from
    /// there.
    let onPick: (SessionPick) -> Void
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
    /// Spawn the session with tool calls held for approval (P3a). Off by
    /// default — ask-first is a choice, not a toll. On a codex session the same
    /// hand means the same thing one notch stricter: `untrusted` asks about
    /// everything, where the default `on-request` asks when codex needs out of
    /// the sandbox.
    @State private var askFirst = false
    /// opus, not the CLI default — the default tier priced a chat at
    /// heavy-lifting rates once already (2026-08-13).
    @State private var model: String = "opus"
    /// Which agent the new tab runs. Claude unless asked otherwise; the
    /// companion is always claude.
    @State private var provider: SessionProvider = .claude
    /// Codex's own dial, kept apart from claude's so flipping the provider
    /// back and forth doesn't hand one provider the other's model name.
    @State private var codexModel: String = ""
    @ObservedObject private var catalog = CodexCatalog.shared
    @FocusState private var focused: Bool

    private var policy: PermissionPolicy { askFirst ? .askFirst : .auto }

    private var pick: (URL) -> SessionPick {
        { url in
            SessionPick(url: url, provider: provider, permissions: policy,
                        model: provider == .codex
                            ? (codexModel.isEmpty ? nil : codexModel)
                            : pickedModel)
        }
    }

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
            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $query,
                    prompt: Text("open a project…").foregroundStyle(.secondary.opacity(0.55))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .focused($focused)
                .onSubmit { if let first = matches.first { onPick(pick(first.url)) } }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }
                providerToggle
                if provider == .codex { codexModelDial } else { modelDial }
                askFirstToggle
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
                        PickerRow(row: row) { onPick(pick(row.url)) }
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

    /// The small hand beside the field — same amber language as the approval
    /// cards, because it's the same idea a step earlier: this session's tools
    /// will wait on you.
    private var pickedModel: String? { model.isEmpty ? nil : model }

    /// Which claude the new tab runs. A quiet word, not a control — click for
    /// the menu. "auto" = whatever the CLI would pick on its own.
    private var modelDial: some View {
        Menu {
            ForEach(SessionManager.modelChoices, id: \.self) { choice in
                Button { model = choice } label: {
                    if choice == model {
                        Label(choice, systemImage: "checkmark")
                    } else {
                        Text(choice)
                    }
                }
            }
            Button { model = "" } label: {
                if model.isEmpty {
                    Label("auto (cli default)", systemImage: "checkmark")
                } else {
                    Text("auto (cli default)")
                }
            }
        } label: {
            Text(model.isEmpty ? "auto" : model)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("model for this session")
    }

    /// Which agent. Only offered when codex is actually installed — an option
    /// that can only fail is worse than no option. Flipping to codex is also
    /// what warms app-server and fetches its model list, so the first turn
    /// isn't paying for both.
    @ViewBuilder
    private var providerToggle: some View {
        if CodexServer.codexPath != nil {
            Button {
                provider = provider == .claude ? .codex : .claude
                if provider == .codex { catalog.loadIfNeeded() }
            } label: {
                HStack(spacing: 4) {
                    if let glyph = provider.glyph {
                        Image(systemName: glyph).font(.system(size: 8, weight: .semibold))
                    }
                    Text(provider.rawValue)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(provider == .codex ? Color.accentColor.opacity(0.9)
                                                    : .secondary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(provider == .codex ? Color.accentColor.opacity(0.14)
                                                      : .white.opacity(0.06))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(provider == .codex ? "a codex session — click for claude"
                                     : "a claude session — click for codex")
        }
    }

    /// Codex's models, from `model/list` — never a list bob keeps. "auto" is
    /// codex's own config choice, and the only thing on offer until the list
    /// lands (or if it never does).
    private var codexModelDial: some View {
        Menu {
            ForEach(catalog.models) { row in
                Button { codexModel = row.id } label: {
                    if row.id == codexModel {
                        Label(row.displayName, systemImage: "checkmark")
                    } else {
                        Text(row.displayName)
                    }
                }
            }
            Button { codexModel = "" } label: {
                if codexModel.isEmpty {
                    Label("auto (codex default)", systemImage: "checkmark")
                } else {
                    Text("auto (codex default)")
                }
            }
        } label: {
            Text(codexModel.isEmpty ? "auto" : codexModel)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("model for this codex session")
    }

    private var askFirstToggle: some View {
        Button { askFirst.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: askFirst ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 9, weight: .medium))
                Text("ask first")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(askFirst ? Color.orange.opacity(0.95) : .secondary.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background { Capsule().fill(askFirst ? Color.orange.opacity(0.16) : .white.opacity(0.06)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(askFirst ? "the session will hold every tool call for your approval"
                       : "spawn holding tool calls for approval")
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
                Image(systemName: session.provider.glyph ?? "terminal")
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

/// The little breathing dot that means "alive right now". The dot can't stop
/// beating (it would read as "done"), and a SwiftUI repeatForever pumps a
/// view-graph transaction plus a whole-window layout every frame — so the
/// beat is a Core Animation animation on a bare layer instead: the render
/// server carries it, the app pays nothing, and it still stops with the
/// window's visibility.
struct PulseDot: View {
    let color: Color
    @Environment(\.windowActivity) private var activity

    var body: some View {
        PulseDotLayer(color: NSColor(color), beating: activity.isVisible)
            .frame(width: 7, height: 7)
    }
}

private struct PulseDotLayer: NSViewRepresentable {
    let color: NSColor
    let beating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let dot = CALayer()
        dot.opacity = 0.9
        view.layer?.addSublayer(dot)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let dot = view.layer?.sublayers?.first else { return }
        dot.frame = view.bounds
        dot.cornerRadius = view.bounds.width / 2
        dot.backgroundColor = color.cgColor
        if beating {
            guard dot.animation(forKey: "beat") == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.5
            scale.toValue = 1.0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 0.9
            let beat = CAAnimationGroup()
            beat.animations = [scale, fade]
            beat.duration = 0.8
            beat.autoreverses = true
            beat.repeatCount = .infinity
            beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(beat, forKey: "beat")
        } else {
            dot.removeAnimation(forKey: "beat")
        }
    }
}
