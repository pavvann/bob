import SwiftUI

/// The center of bob — the conductor. Which claude it fronts follows the
/// manager's active session: bob-the-companion gets the whole familiar face
/// (greeting, voice, lenses, palette — the path below is byte-identical to
/// before tabs existed), while an active work session gets WorkStage — same
/// thread visuals, none of the persona. The tabs in the band switch between
/// them.
struct CenterStage: View {
    @ObservedObject var bridge: ClaudeBridge
    @ObservedObject var voiceIn: VoiceInput
    @ObservedObject var voiceOut: VoiceOutput
    @ObservedObject var home: BobHome

    /// First-name initial used in the greeting. Single letter, not identifying.
    var initialName: String = "p"

    /// One extra esc layer owned by the container: ContentView closes its
    /// project picker here. Runs after interrupt, before NSApp.hide — so esc
    /// can never hide bob while the picker is still up.
    var interceptHide: () -> Bool = { false }

    @ObservedObject private var manager = SessionManager.shared
    @ObservedObject private var pulse = BobPulse.shared
    @ObservedObject private var minions = MinionService.shared
    @ObservedObject private var openLine = OpenLine.shared
    @ObservedObject private var slash = SlashCommandService.shared
    @ObservedObject private var router = SurfaceRouter.shared

    @State private var input: String = ""
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    /// The dispatch acknowledgment — "→ webapp: fix the failing test" — shown
    /// briefly above the input bar after a `>name …` send, then gone.
    @State private var whisper: String?
    @State private var whisperSweep: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    /// The work session on stage, if any. The companion (and the legacy
    /// no-manager path, where active is nil) renders the classic face; the
    /// switch itself only needs the manager's activeID — WorkStage observes
    /// the session object directly for entries and state.
    private var activeWork: SessionRef? { manager.activeWorkTab }

    /// Bob's own session, by id rather than `sessions.first` — in compatibility
    /// mode there is no companion at all, and index 0 is then somebody else.
    private var companionSession: ClaudeSession? {
        guard let id = manager.companionID else { return nil }
        return manager.sessions.first { $0.id == id }
    }

    var body: some View {
        // A surface (notes, canvas) takes the whole stage — even over an active
        // work tab, which keeps running behind its band chip. The companion
        // face hosts it: the input bar underneath always talks to bob.
        if router.active == nil, let work = activeWork {
            // one switch, one stage: the provider picks the concrete session
            // type SwiftUI needs to observe, and nothing below this line forks.
            // `.id` gives each tab fresh field/scroll state, so drafts never
            // leak between sessions.
            switch work {
            case .claude(let session):
                WorkStage(session: session, interceptHide: interceptHide).id(session.id)
            case .codex(let session):
                WorkStage(session: session, interceptHide: interceptHide).id(session.id)
            }
        } else {
            companion
        }
    }

    // MARK: - the companion face (unchanged behavior)

    /// The resting screen, or the thread. Notices don't count as conversation:
    /// a system whisper ("running in compatibility mode") shouldn't take over
    /// bob's face at launch — it shows in the thread the moment there's one.
    private var isIdle: Bool {
        !bridge.isStreaming && !bridge.transcript.entries.contains { $0.role != .notice && !$0.hidden }
    }

    /// Which notice rows are up — the one thing in the thread that comes and
    /// goes on its own (see the animation on the turn list).
    private var noticeRows: [UUID] {
        bridge.transcript.entries.filter { $0.role == .notice }.map(\.id)
    }

    private var companion: some View {
        VStack(spacing: 24) {
            if let surface = router.active {
                surfaceStage(surface)
            } else {
                stage
            }
            VStack(alignment: .leading, spacing: 8) {
                // two whispers, stacked when they overlap: bob's clamped reply
                // (his voice — click to rejoin the thread) above the dispatch
                // ack (the room's voice, gone in a beat).
                if router.active != nil, surfaceReplyEntry != nil || bridge.isStreaming {
                    SurfaceReplyStrip(entry: surfaceReplyEntry, streaming: bridge.isStreaming) {
                        router.close()
                        // the strip is the companion's reply — clicking it means
                        // "show me the conversation", not whichever work tab
                        // happened to be on stage before the surface went up.
                        if let cid = manager.companionID { manager.activate(cid) }
                    }
                }
                if let whisper { DispatchWhisper(text: whisper) }
                // the caption is a sibling of the bar, not a passenger: it sits
                // outside the material fill and outside AnimatedBorder's bleed,
                // so the comet stroke still encloses exactly the input box.
                VStack(alignment: .trailing, spacing: 5) {
                    inputBar
                        .overlay(alignment: .top) { slashPalette }
                    if let companion = companionSession {
                        SessionMeterCaption(session: companion)
                            .padding(.trailing, 8)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: whisper)
            .animation(.easeInOut(duration: 0.25), value: surfaceReplyEntry == nil)
        }
        .animation(.easeInOut(duration: 0.3), value: router.active)
        .onAppear {
            inputFocused = true
            refreshPulse()
            openLine.refreshIfStale()
            // bob speaks each sentence as it streams (no-op unless voice is on).
            bridge.onSentence = { [weak voiceOut] sentence in
                voiceOut?.speakSentence(sentence)
            }
        }
        .onChange(of: isIdle) { _, idle in
            // back to the resting screen — freshen bob's open line
            if idle { openLine.refreshIfStale() }
        }
        .animation(.easeInOut(duration: 0.6), value: openLine.line)
        .onChange(of: input) { _, _ in
            // any edit reopens a dismissed palette and rests the highlight —
            // standard palette feel, and it makes Esc's dismissal one-shot.
            slashDismissed = false
            slashSelection = 0
            if input.hasPrefix("/") { slash.refresh() }
        }
        .onChange(of: voiceIn.transcript) { _, newValue in input = newValue }
        .onChange(of: voiceIn.isRecording) { _, _ in refreshPulse() }
        .onChange(of: bridge.isStreaming) { _, _ in refreshPulse() }
        .onChange(of: inputFocused) { _, _ in refreshPulse() }
        .onChange(of: minions.active.count) { _, _ in refreshPulse() }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyManager.didSummon)) { _ in
            // ⌥Space brought bob to the front — drop the cursor straight in the box.
            inputFocused = true
        }
        .animation(.easeInOut(duration: 0.35), value: isIdle)
    }

    /// Tell bob's pulse what's happening so the whole app's rhythm follows.
    private func refreshPulse() {
        pulse.refresh(
            focused: inputFocused,
            streaming: bridge.isStreaming,
            listening: voiceIn.isRecording,
            minions: minions.active.count
        )
    }

    // MARK: stage (greeting or response)

    @ViewBuilder
    private var stage: some View {
        if isIdle {
            VStack(spacing: 8) {
                BreathingGreeting(text: greeting, period: pulse.breathPeriod)
                    // retempo = recreate: energy moves in rare, discrete steps,
                    // and one clean restart beats display-rate body evals
                    .id(pulse.breathPeriod)
                    .fixedSize()
                // bob's own line about your day — picks up where you left off
                if home.status == .ready, let line = openLine.line, home.welcomeNote == nil {
                    Text(line)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                        .padding(.horizontal, 24)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if case .bootstrapping(let msg) = home.status {
                    Text(msg)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.55))
                } else if let note = home.welcomeNote {
                    Text(note)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            // hidden entries (debrief injections) are dropped here and nowhere
            // else — that filter is the whole reason a debrief shows only
            // bob's reply
            let rows = bridge.transcript.entries.filter { !$0.hidden }
            let inFlightID = self.inFlightID   // once per body, not once per row
            ScrollViewReader { proxy in
                GeometryReader { geo in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(rows) { entry in
                                TurnRowView(
                                    entry: entry,
                                    // scoped to the in-flight row: handing every
                                    // row the global streaming bool re-rendered
                                    // (and re-parsed) the whole thread per toggle
                                    inFlight: entry.id == inFlightID
                                )
                            }
                            FollowTail(store: bridge.transcript, proxy: proxy)
                        }
                        .padding(.vertical, 4)
                        // a short thread bottom-aligns by LAYOUT: with less
                        // content than viewport there is no scroll range for
                        // scrollTo to work with, and a second offset owner
                        // (defaultScrollAnchor) is what caused the CPU storm
                        .frame(minHeight: geo.size.height, alignment: .bottom)
                        // task notices are live status — they sweep themselves once
                        // the task settles. Keyed on just the notice rows so their
                        // arrival and departure fade while ordinary turns keep
                        // landing instantly.
                        .animation(.easeInOut(duration: 0.3), value: noticeRows)
                    }
                    .scrollIndicators(.never)
                    .onAppear {
                        // a restored thread should open reading its newest turn
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
                // takes whatever height the window offers, up to this — tall
                // enough that a real conversation reads like a thread instead of
                // a letterbox. Bottom-anchoring is manual (the layout frame
                // above + onAppear/onChange scrollTo): stacking
                // .defaultScrollAnchor(.bottom) on top of the scrollTo gave the
                // scroll view two owners of its offset, and every
                // content-height change had them re-pinning each other per
                // frame — the idle-transcript CPU storm.
                .frame(maxHeight: 520)
            }
            .transition(.opacity)
        }
    }

    /// The turn bob is speaking into right now — the newest .bob row, while
    /// streaming. Not "the last row": send() echoes the queued .you entry
    /// immediately, and a task notice can land mid-reply — neither may steal
    /// the thinking orb from a still-empty reply.
    private var inFlightID: UUID? {
        guard bridge.isStreaming else { return nil }
        return bridge.transcript.entries.last(where: { $0.role == .bob })?.id
    }

    // MARK: surfaces (notes, canvas)

    /// The mounted surface, in the slot the thread normally holds. Esc from
    /// inside it (the notes editor, the empty plane) closes the surface via
    /// onExitCommand — but a canvas card mid-edit sits closer in the responder
    /// chain, so its own commit-on-Esc still wins.
    @ViewBuilder
    private func surfaceStage(_ surface: AppSurface) -> some View {
        Group {
            switch surface {
            case .notes:  NotesSurface()
            case .canvas: CanvasSurface()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { router.close() }
        .transition(.opacity)
    }

    /// What the strip whispers: bob's latest reply, or the one landing right
    /// now (empty while he's still thinking — the strip shows a beat of "…").
    /// Nil when there's no conversation to keep audible. The entry, not its
    /// text: the strip is the leaf that reads the growing string.
    private var surfaceReplyEntry: TranscriptEntry? {
        bridge.transcript.entries.last(where: { $0.role == .bob && !$0.hidden })
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 12) {
            if voiceIn.isRecording {
                // the box comes to life — a live waveform of your voice, with
                // what bob's heard so far as a faint caption underneath.
                VStack(alignment: .leading, spacing: 3) {
                    WaveformView(levels: voiceIn.levels)
                        .frame(height: 24)
                    if !input.isEmpty {
                        Text(input)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 24)
                .transition(.opacity)
            } else {
                TextField(
                    "",
                    text: $input,
                    prompt: Text(placeholder).foregroundStyle(.secondary.opacity(0.6)),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .focused($inputFocused)
                .lineLimit(1...4)
                .onSubmit(send)
                .submitLabel(.send)
                .onKeyPress(.escape) {
                    // esc peels exactly one layer per press: palette → text in
                    // the box → bob mid-reply → the container's layer (project
                    // picker) → an open surface → the whole app.
                    if !slashMatches.isEmpty {
                        slashDismissed = true
                    } else if !input.isEmpty {
                        input = ""
                    } else if bridge.isStreaming {
                        // an interrupt, not a kill — the session survives and
                        // takes the next message. So esc here means "stop
                        // talking", never "go away": bob stays on screen and
                        // the voice stops with the text.
                        bridge.cancel()
                        voiceOut.stop()
                    } else if interceptHide() {
                        // the picker was up — it ate this press and closed
                    } else if router.close() {
                        // a surface was up — back to whatever held the stage
                    } else {
                        NSApp.hide(nil)
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !slashMatches.isEmpty else { return .ignored }
                    slashSelection = max(0, slashSelected - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !slashMatches.isEmpty else { return .ignored }
                    slashSelection = min(slashMatches.count - 1, slashSelected + 1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard !slashMatches.isEmpty else { return .ignored }
                    completeSlash(slashMatches[slashSelected])
                    return .handled
                }
                .transition(.opacity)
            }

            lensChip
            micButton
            speakerButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            // No padding here — AnimatedBorder owns its own bleed, so the
            // surface and the stroke can never drift out of agreement again.
            AnimatedBorder(
                cornerRadius: 26,
                voiceLevel: Double(voiceIn.level),
                energy: pulse.energy
            )
        }
        .animation(.easeInOut(duration: 0.25), value: voiceIn.isRecording)
        .animation(.easeInOut(duration: 0.2), value: bridge.activeLens)
    }

    /// The mode bob is in, if any — `@music`, `@project:webapp`. Sits just left
    /// of the mic; click it to drop back to plain bob.
    @ViewBuilder
    private var lensChip: some View {
        if let lens = bridge.activeLens {
            // setLens, not a direct write: dropping the lens respawns the
            // session with the plain system prompt (D4), and the chip goes
            // down the moment you click it.
            Button { bridge.setLens(nil) } label: {
                Text("@\(lens)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background { Capsule().fill(Color.accentColor.opacity(0.14)) }
            }
            .buttonStyle(.plain)
            .help("\(lens) lens is on — click to clear (or send @none)")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    // MARK: slash palette

    /// The token being typed after a leading `/` — nil once a space is typed
    /// (you're writing arguments now) or while the mic owns the box. `/` and
    /// `@` never collide: a lens starts with `@`, a command with `/`.
    private var slashQuery: String? {
        guard !voiceIn.isRecording, input.hasPrefix("/") else { return nil }
        let token = input.dropFirst()
        guard !token.contains(where: { $0.isWhitespace }) else { return nil }
        return String(token)
    }

    private var slashMatches: [SlashCommand] {
        guard !slashDismissed, let q = slashQuery else { return [] }
        return slash.matches(q, in: .companion)
    }

    /// Selection clamped to the live match list — arrows move it, every
    /// keystroke rests it back to the top.
    private var slashSelected: Int {
        min(slashSelection, max(0, slashMatches.count - 1))
    }

    @ViewBuilder
    private var slashPalette: some View {
        if !slashMatches.isEmpty {
            SlashPalette(matches: slashMatches, selected: slashSelected) { cmd in
                completeSlash(cmd)
                inputFocused = true
            }
            .frame(maxWidth: .infinity)
            // sit fully above the bar: this view's bottom+8 becomes its top
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .transition(.opacity)
        }
    }

    /// Put the picked name in the box, trailing space ready for arguments.
    /// The space also hides the palette, so Enter now sends as usual.
    private func completeSlash(_ cmd: SlashCommand) {
        input = "/" + cmd.name + " "
    }

    private var micButton: some View {
        Button(action: toggleVoice) {
            ZStack {
                Circle()
                    .fill(voiceIn.isRecording ? Color.accentColor.opacity(0.18) : Color.clear)
                    .frame(width: 26, height: 26)
                Image(systemName: voiceIn.isRecording ? "waveform" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(voiceIn.isRecording ? Color.accentColor : .secondary)
                    .symbolEffect(.pulse, isActive: voiceIn.isRecording)
            }
        }
        .buttonStyle(.plain)
        .help(voiceIn.isRecording ? "stop listening" : "speak to bob")
    }

    private var speakerButton: some View {
        Button {
            voiceOut.enabled.toggle()
            if !voiceOut.enabled { voiceOut.stop() }
        } label: {
            Image(systemName: voiceOut.enabled ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(voiceOut.enabled ? "bob speaks responses" : "bob is silent")
    }

    // MARK: behaviour

    private var placeholder: String {
        if case .bootstrapping = home.status { return "getting set up..." }
        if bridge.isStreaming { return "..." }
        if voiceIn.isRecording { return "listening..." }
        if let status = voiceIn.status { return status }
        return "talk to bob"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let opener: String
        switch hour {
        case 5..<12:  opener = "morning"
        case 12..<17: opener = "hey"
        case 17..<22: opener = "evening"
        default:      opener = "still up"
        }
        return "\(opener), \(initialName)."
    }

    private func send() {
        // Enter with the palette up completes the highlighted name; Enter on a
        // name that's already complete falls through and sends. A `/command`
        // message goes to claude verbatim — the CLI expands and runs it in -p,
        // in-session, with the active lens riding along untouched.
        if !slashMatches.isEmpty {
            let cmd = slashMatches[slashSelected]
            if input.trimmingCharacters(in: .whitespaces) != "/" + cmd.name {
                completeSlash(cmd)
                return
            }
        }

        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // A leading `>name` is the owner's hand on a work session (D9) —
        // routed straight there, no model in the loop, mirroring the @lens
        // parse below. Anything short of an unambiguous match falls through
        // to bob verbatim, so he can see the attempt and say what's close.
        if let ack = routeDispatch(raw, via: manager) {
            input = ""
            home.welcomeNote = nil
            showWhisper(ack)
            return
        }

        // `/model` is bob's own dial, not a CLI command: bare = say the current
        // model, `/model opus` switches this conversation in place (the same
        // drain doorway a lens swap uses — history intact). Unknown names fall
        // through to bob verbatim, like a lens typo. Work tabs pick theirs in
        // the "+" picker instead.
        if let ack = Self.modelCommand(raw, manager: manager) {
            input = ""
            home.welcomeNote = nil
            showWhisper(ack)
            return
        }

        // `/resume` raises this project's own history — the CLI's gesture,
        // pointed at bob's thread. Intercepted locally for the same reason
        // `/model` is: sent verbatim it would just be words to the model.
        if Self.isResumeCommand(raw), let companion = manager.companion {
            input = ""
            home.welcomeNote = nil
            ResumeStore.shared.open(for: companion)
            return
        }
        input = ""
        home.welcomeNote = nil

        // A leading `@token` picks the session's lens and is stripped from what
        // bob sees: `@music play something moody` switches and sends the rest,
        // `@music` alone only switches, `@none` clears. An unknown token is left
        // in the text untouched — a typo reaches bob as words, never as a mode.
        var prompt = raw
        if let (spec, rest) = Self.lensPrefix(raw) {
            if spec.lowercased() == "none" || spec.lowercased() == "off" {
                bridge.setLens(nil)
                prompt = rest
            } else if LensStore.shared.resolve(spec) != nil {
                // resolving here is the honest gate: the chip only goes up for a
                // lens that actually assembles (file present, argument supplied).
                // This copy is thrown away — the bridge resolves it again when
                // it swaps the lens in, so an edit to the lens file lands the
                // next time you name it (a lens now rides a whole process, not
                // a single turn — plan D4.3).
                bridge.setLens(spec)
                prompt = rest
            }
        }

        guard !prompt.isEmpty else { return }   // lens switch only — nothing to say
        voiceOut.stop()
        bridge.send(prompt)
    }

    /// Put the ack up and take it down again after a beat — long enough to
    /// read, short enough that the thread stays bob's.
    private func showWhisper(_ line: String) {
        whisper = line
        whisperSweep?.cancel()
        whisperSweep = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            whisper = nil
        }
    }

    /// Splits a leading `@<token>` off a message: `("music", "play something")`.
    /// Nil when the message doesn't start with one.
    /// `/resume` (bare, or with trailing spaces) opens the conversation picker
    /// for whichever session is asking. Arguments are ignored rather than
    /// guessed at — the list is the interface.
    static func isResumeCommand(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).lowercased() == "/resume"
    }

    /// The claude command a message *is* — `/ship`, `/vercel:deploy args` — and
    /// nil for everything else. The name has to be one the palette really
    /// carries, which is what keeps a message that merely starts with a slash
    /// (a path, a regex) travelling as the words it is rather than being read
    /// as a command nobody typed.
    static func claudeCommandName(_ raw: String) -> String? {
        let head = String(raw.split(separator: " ", maxSplits: 1).first ?? "")
        guard head.hasPrefix("/"), head.count > 1 else { return nil }
        let name = String(head.dropFirst())
        guard !name.contains("/") else { return nil }
        return SlashCommandService.shared.isClaudeCommand(name) ? name : nil
    }

    /// `/model` → whisper the current model; `/model opus|sonnet|haiku|fable`
    /// → switch the companion in place; `/model default` → back to the CLI's
    /// own choice. Returns the whisper ack, or nil when the text isn't a model
    /// command at all (so it reaches bob as words).
    static func modelCommand(_ raw: String, manager: SessionManager) -> String? {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first?.lowercased() == "/model",
              let companion = manager.companion else { return nil }
        guard parts.count > 1 else {
            let current = companion.config.model ?? "cli default"
            return "bob runs on \(current) — /model "
                 + SessionManager.modelChoices.joined(separator: "·") + "·default"
        }
        let word = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        if word == "default" {
            manager.setModel(nil, for: companion.id)
            return "→ model: cli default — same conversation"
        }
        guard SessionManager.modelChoices.contains(word) else { return nil }
        manager.setModel(word, for: companion.id)
        return "→ model: \(word) — same conversation, new brain"
    }

    private static func lensPrefix(_ text: String) -> (spec: String, rest: String)? {
        guard text.hasPrefix("@") else { return nil }
        let body = text.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        // "@music," / "@music." — punctuation belongs to the sentence, not the name
        let spec = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        guard !spec.isEmpty else { return nil }
        let rest = String(body.dropFirst(token.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (spec, rest)
    }

    private func toggleVoice() {
        if voiceIn.isRecording {
            voiceIn.stop()
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                send()
            }
        } else {
            input = ""
            voiceIn.start()
        }
    }
}

/// The idle greeting's breath — a few settling breaths, then stillness. It
/// must not breathe forever: any SwiftUI-driven animation pumps a view-graph
/// transaction per frame, and each transaction re-runs layout for the whole
/// window — profiled at a full core once a transcript was on stage. So the
/// rule every idle flourish follows: ease in, breathe briefly, hold. The odd
/// repeat count ends the reversing ease exactly on the model value, so the
/// freeze lands without a snap; the caller keys this view's identity on
/// `period`, so a tempo change replays the settling breaths once.
private struct BreathingGreeting: View {
    let text: String
    /// Full breath cycle in seconds (`BobPulse.breathPeriod`).
    let period: Double

    @State private var inhale = false

    var body: some View {
        Text(text)
            .font(.system(size: 38, weight: .light, design: .rounded))
            .foregroundStyle(.primary.opacity(0.88))
            .scaleEffect(inhale ? 1.012 : 0.988)
            .opacity(inhale ? 1.0 : 0.84)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2).repeatCount(5, autoreverses: true)) {
                    inhale = true
                }
            }
    }
}

// MARK: - one turn, either stage

/// One turn in a running conversation. Your turns sit right-aligned and muted
/// (an echo of what you said); the reply is left, full reading weight; notices
/// are a whisper the conversation flows around. Minimal — a thread, not chat
/// bubbles. Shared verbatim by the companion thread and WorkStage, so the two
/// stages can never drift apart visually.
///
/// Reads its own entry: with Observation, a streamed token growing the tail's
/// text re-runs THIS row's body and nothing else — completed rows never move.
private struct TurnRowView: View {
    let entry: TranscriptEntry
    /// This is the turn being spoken into right now: it holds the activity
    /// slot, and while its reply is still empty it shows the thinking orb.
    /// Only ever true for the last row — historical rows must receive a
    /// constant here, or every streaming toggle re-renders the whole thread.
    let inFlight: Bool

    var body: some View {
        switch entry.role {
        case .you:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        case .bob:
            VStack(alignment: .leading, spacing: 5) {
                if entry.text.isEmpty && inFlight {
                    // a quiet breathing dot where the reply will appear
                    ThinkingOrb()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else if let render = entry.render {
                    // claude writes markdown; render it as markdown (tables,
                    // fences, lists, emphasis) — from the entry's model,
                    // which parsed each block exactly once as it arrived
                    StreamedMarkdownText(model: render)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .transition(.opacity)
                } else {
                    // every bob row carries a model; kept for form, not for
                    // a case that happens
                    MarkdownText(text: entry.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
                activityLine
            }
        case .notice:
            // system aside — a background task landing, a session reconnecting,
            // the compatibility-mode fallback. Dim, small, out of the way; it
            // reads as the room talking, not as bob.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text(entry.text)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    /// What the session's hands are doing right now — "reading Foo.swift" —
    /// under the streaming reply. Only the in-flight turn carries one. The
    /// slot keeps its height for as long as that turn is live, so a tool
    /// starting and ending mid-reply fades in and out instead of shoving the
    /// text around; it collapses once, when the reply lands.
    @ViewBuilder
    private var activityLine: some View {
        if entry.activity != nil || inFlight {
            Text(entry.activity ?? " ")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(entry.activity == nil ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.18), value: entry.activity)
        }
    }
}

/// The tail sentinel and the ONE manual scroll follow (the storm fix: a
/// single owner of the scroll offset, never animated — see the notes on the
/// containers). Reading `revision` here, and only here, means a growing reply
/// re-evaluates this zero-size leaf per coalesced flush while the rows above
/// stay quiet.
private struct FollowTail: View {
    let store: TranscriptStore
    let proxy: ScrollViewProxy

    var body: some View {
        // the explicit read is the subscription — body must observe the
        // revision for the onChange below to be woken at all
        let revision = store.revision
        Color.clear.frame(height: 1).id("end")
            .onChange(of: revision) { _, _ in
                // not animated: this fires per coalesced flush, and an
                // animated scroll restarted 30×/sec is pure churn
                proxy.scrollTo("end", anchor: .bottom)
            }
    }
}

// MARK: - the work stage

/// Center stage for a WORK session — a raw claude or a codex thread living in a
/// project directory. Same thread visuals as the companion (TurnRowView), none
/// of the persona: no greeting face, no voice, no lens chip, no @lens parsing.
/// Everything else in the box goes to the session verbatim (slash commands
/// included; claude expands them in-session). Input routes through the manager
/// so a cold restored tab wakes on first send.
///
/// The `/` palette is here too, and it is scoped to the provider: claude's tabs
/// get claude's commands because the CLI really does expand them in `-p`, codex
/// tabs get only the ones bob runs itself — see `SlashCommandService.Scope`.
private struct WorkStage<S: StageSession>: View {
    @ObservedObject var session: S
    var interceptHide: () -> Bool = { false }

    @State private var input = ""
    @State private var palette = SlashPaletteState()
    @State private var whisper: String?
    @State private var whisperSweep: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @ObservedObject private var broker = UIPermissionBroker.shared
    @ObservedObject private var slash = SlashCommandService.shared

    /// The palette's question carries both halves: which agent is behind this
    /// tab, and which project it runs in. A work tab is rarely `~/bob`, so the
    /// second half is what stops the palette offering the companion's commands.
    private var slashScope: SlashCommandService.Scope {
        .work(provider: session.provider, cwd: session.cwd)
    }

    /// Nothing is hidden in a work session today, but the filter keeps parity
    /// with the companion thread if P3 ever injects into one.
    private var entries: [TranscriptEntry] { session.transcript.entries.filter { !$0.hidden } }

    var body: some View {
        VStack(spacing: 24) {
            stage
            VStack(alignment: .leading, spacing: 8) {
                if let whisper { DispatchWhisper(text: whisper) }
                // the ask card, where the eyes already are. It also lives on
                // the tab chip in the band, and both read one broker — so
                // answering in either place closes both. Never dismissible:
                // an unanswered codex approval parks its thread forever, so
                // there is no gesture here that makes the question go away
                // without answering it.
                if let ask = broker.ask(for: session.id) {
                    PermissionAskCard(ask: ask)
                        .frame(maxWidth: 460, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                // same shape as the companion's: outside the bar's fill and
                // outside the border's bleed
                VStack(alignment: .trailing, spacing: 5) {
                    inputBar
                    SessionMeterCaption(session: session)
                        .padding(.trailing, 8)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: whisper)
            .animation(.easeInOut(duration: 0.2), value: broker.ask(for: session.id)?.id)
        }
        .onAppear {
            inputFocused = true
            // scan this project's commands now, not on the first keystroke, so
            // the first `/` is already complete. Once per launch per project.
            slash.warm(slashScope)
        }
        .onReceive(NotificationCenter.default.publisher(for: HotKeyManager.didSummon)) { _ in
            inputFocused = true
        }
        .animation(.easeInOut(duration: 0.35), value: entries.isEmpty)
    }

    // MARK: stage

    @ViewBuilder
    private var stage: some View {
        if entries.isEmpty {
            // no greeting here — that face is the companion's. Just where you
            // are and whether it's awake yet.
            VStack(spacing: 8) {
                Text(session.displayName)
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                Text(idleHint)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .multilineTextAlignment(.center)
                if case .down = session.phase { retryButton }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            let rows = entries   // filter once, not once per row
            // the newest bob entry, while streaming — not "the last row", see
            // the companion thread's inFlightID
            let inFlightID = session.isStreaming
                ? rows.last(where: { $0.role == .bob })?.id
                : nil
            VStack(alignment: .leading, spacing: 8) {
                header
                ScrollViewReader { proxy in
                    GeometryReader { geo in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(rows) { entry in
                                    TurnRowView(
                                        entry: entry,
                                        // scoped like the companion thread's rows
                                        inFlight: entry.id == inFlightID
                                    )
                                }
                                FollowTail(store: session.transcript, proxy: proxy)
                            }
                            .padding(.vertical, 4)
                            // a short thread bottom-aligns by layout — see the
                            // companion thread's note
                            .frame(minHeight: geo.size.height, alignment: .bottom)
                        }
                        .scrollIndicators(.never)
                        .onAppear {
                            // manual bottom-follow, same as the companion thread —
                            // see the storm note there before re-adding an anchor
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                    }
                    .frame(maxHeight: 500)
                }
            }
            .transition(.opacity)
        }
    }

    /// A slim breadcrumb over the thread — whose conversation you're reading,
    /// what it's set to, and the way back up if it's down.
    private var header: some View {
        HStack(spacing: 6) {
            if let glyph = session.provider.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
            } else {
                Image(systemName: "folder")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            Text(session.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            Text(cwdTail)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            // a session that went down mid-conversation must never be a dead
            // end: codex reaches `.failed` whenever app-server dies under a
            // perfectly healthy thread, and the retry resumes that same thread
            if case .down = session.phase { retryButton }
            if let codex = session.codexSession { CodexDial(session: codex) }
        }
    }

    private var retryButton: some View {
        Button { session.retry() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .semibold))
                Text("retry").font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.orange.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { Capsule().fill(.orange.opacity(0.14)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("open this session again — the conversation comes back with it")
    }

    private var idleHint: String {
        switch session.phase {
        case .cold:
            return "cold — say something and it wakes"
        case .waking:
            return "waking up in \(cwdTail)…"
        case .down(let reason):
            return "session is down (\(reason))"
        default:
            return session.provider == .codex
                ? "codex in \(cwdTail) — writes scoped here, approvals come to you"
                : "a raw claude in \(cwdTail) — no lens, no voice, just the project"
        }
    }

    private var cwdTail: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.cwd.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField(
                "",
                text: $input,
                prompt: Text(placeholder).foregroundStyle(.secondary.opacity(0.6)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .focused($inputFocused)
            .lineLimit(1...4)
            .onSubmit(send)
            .submitLabel(.send)
            .onKeyPress(.escape) {
                // same layer-peel as the companion, minus voice: palette →
                // text in the box → the session mid-reply → the container's
                // picker → back to bob → the whole app. Interrupt goes to THIS
                // session. A work tab gets that one extra layer the companion
                // doesn't need: esc steps off this session before it means
                // "hide bob", so leaving a tab never costs you the window.
                if palette.dismissOnEscape(input, scope: slashScope) {
                    // the sheet was up — this press closed it and nothing else
                } else if !input.isEmpty {
                    input = ""
                } else if session.isStreaming {
                    session.interrupt()
                } else if interceptHide() {
                    // the picker was up — it ate this press and closed
                } else if SessionManager.shared.companionID != nil {
                    SessionManager.shared.goHome()
                } else {
                    NSApp.hide(nil)
                }
                return .handled
            }
            .slashPaletteKeys($palette, input: $input, scope: slashScope)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            AnimatedBorder(
                cornerRadius: 26,
                voiceLevel: 0,
                energy: session.isStreaming ? 0.7 : 0.2
            )
        }
        .slashPaletteSheet($palette, input: $input, scope: slashScope)
    }

    private var placeholder: String {
        switch session.phase {
        case .waking: return "waking up…"
        case .busy: return "..."
        case .down: return "session is down"
        default: return "message \(session.displayName)"
        }
    }

    private func send() {
        // Enter with the palette up completes the highlighted name; Enter on a
        // name that's already complete falls through and sends.
        if palette.completeOnEnter(&input, scope: slashScope) { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        // `>name …` works from any stage — commanding a sibling session (or
        // this one) without walking back to the companion first.
        if let ack = routeDispatch(prompt, via: SessionManager.shared) {
            input = ""
            showWhisper(ack)
            return
        }
        // this tab's own history — the picker resumes into this session, not
        // into bob's thread (same command, whichever stage you're standing on).
        // One store, one overlay, either provider: claude's rows come off disk,
        // codex's out of `thread/list`.
        if CenterStage.isResumeCommand(prompt) {
            if let claude = session.claudeSession {
                input = ""
                ResumeStore.shared.open(for: claude)
                return
            }
            if let codex = session.codexSession {
                input = ""
                ResumeStore.shared.open(for: codex)
                return
            }
        }
        // A claude command typed on a codex tab, from muscle memory. It is not
        // in this tab's palette, and sending it would make codex answer a
        // question about a command it has never heard of — so say so once
        // instead. Gated on the name really being one of claude's, which is
        // what keeps a message that merely starts with a slash (`/tmp/x`, a
        // path, a regex) travelling as the words it is.
        if session.provider == .codex, let name = CenterStage.claudeCommandName(prompt) {
            input = ""
            showWhisper("/\(name) is claude's — codex tabs run /resume and codex's own tools")
            return
        }
        input = ""
        // verbatim — no @lens parsing. A `/command` rides as a plain message and
        // claude expands it in-session. Routed through the manager so a cold tab
        // spawns before the text would be lost.
        SessionManager.shared.send(prompt, to: session.id)
    }

    private func showWhisper(_ line: String) {
        whisper = line
        whisperSweep?.cancel()
        whisperSweep = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            whisper = nil
        }
    }
}

// MARK: - `>` dispatch (D9 — the owner's hand)

/// Route a `>name …` message at its work session, from whichever stage it was
/// typed on. Returns the whisper line to show, or nil when the text should
/// travel as ordinary words instead — ambiguous and unknown names fall through
/// on purpose, so bob (or the raw session) sees the attempt verbatim and can
/// say so; a command is never silently swallowed.
@MainActor
private func routeDispatch(_ raw: String, via manager: SessionManager) -> String? {
    let keyed = dispatchKeys(manager.workTabs)
    guard case .send(let name, let text, let bang) =
            SessionDispatch.parse(raw, names: Array(keyed.keys)),
          let target = keyed[name]
    else { return nil }
    if bang {
        manager.stopAndTell(text, to: target.id)
    } else {
        manager.inject(text, into: target.id)
    }
    return "→ \(name)\(bang ? " (stopped)" : ""): \(text)"
}

/// What `>` can address, and nothing it can address twice.
///
/// A claude tab and a codex tab in the same directory get the same default
/// name, and `>project` taking the first of them means the other is
/// unreachable and `>project!` may stop the wrong one — a silently wrong target
/// is the worst outcome this feature has. So a name shared by two tabs is
/// replaced by `name/claude` and `name/codex`, which leaves the bare name
/// matching neither exactly and both by prefix: ambiguous, which the parser
/// already handles by declining. A unique name is untouched, so `>web` and
/// `>we` stay as terse as they were. Two tabs that still collide after
/// qualification (two claude tabs in same-named directories — true before codex
/// existed) drop out entirely rather than being guessed at.
/// Internal rather than private so the rule can be checked directly, the same
/// reason `SessionDispatch` beside it is.
@MainActor
func dispatchKeys(_ tabs: [SessionRef]) -> [String: SessionRef] {
    var counts: [String: Int] = [:]
    for tab in tabs { counts[tab.name, default: 0] += 1 }
    var keyed: [String: SessionRef] = [:]
    var collided: Set<String> = []
    for tab in tabs {
        let key = counts[tab.name] == 1 ? tab.name : "\(tab.name)/\(tab.provider.rawValue)"
        if keyed[key] != nil { collided.insert(key) } else { keyed[key] = tab }
    }
    for key in collided { keyed[key] = nil }
    return keyed
}

/// The whisper strip — while a surface holds the stage, bob's reply stays
/// audible here: dim, two lines, notice-styled, right above the input bar.
/// The dot warms to accent while he's still talking. Click it to put the
/// conversation back on stage. Takes the live entry, not its text: this leaf
/// is the only thing over a surface that re-renders per streamed flush.
private struct SurfaceReplyStrip: View {
    let entry: TranscriptEntry?
    let streaming: Bool
    let onTap: () -> Void

    var body: some View {
        let text = entry?.text ?? ""
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺")
                    .font(.system(size: 8))
                    .foregroundStyle(streaming ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.4))
                Text(text.isEmpty ? "…" : text)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("back to the conversation")
        .transition(.opacity)
    }
}

/// The dispatch acknowledgment — styled exactly like a notice row (the room
/// talking, not bob), floating above the input bar for a beat.
private struct DispatchWhisper: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("⏺")
                .font(.system(size: 8))
                .foregroundStyle(.secondary.opacity(0.4))
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// The `>` command grammar, mirroring the @lens parse: `>webapp fix the test`
/// sends into the session called webapp, `>webapp! stop, run the tests` stops
/// it first (the ONLY road to an interrupt — never implicit). Names match by
/// unambiguous case-insensitive prefix; an exact name beats a longer cousin.
/// Pure, so the harness can table-test every verdict.
enum SessionDispatch {
    enum Verdict: Equatable {
        /// Not a dispatch at all — no `>` head, `> quoted text`, or a name
        /// with nothing to say after it.
        case none
        /// `>web …` with webapp AND webapi alive — the message travels
        /// verbatim; bob can list what was close.
        case ambiguous([String])
        /// `>zzz …` — no session answers to that; verbatim again.
        case noMatch(String)
        /// The one clean verdict: a full session name, the text, and whether
        /// the bang (stop-first) was on it.
        case send(name: String, text: String, bang: Bool)
    }

    static func parse(_ raw: String, names: [String]) -> Verdict {
        guard raw.hasPrefix(">") else { return .none }
        let body = raw.dropFirst()
        let token = String(body.prefix { !$0.isWhitespace })
        guard !token.isEmpty else { return .none }   // "> a quote" — just words
        let text = String(body.dropFirst(token.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }    // nothing to deliver — words for bob
        var name = token
        var bang = false
        if name.hasSuffix("!") {
            bang = true
            name.removeLast()
        }
        guard !name.isEmpty else { return .none }
        let query = name.lowercased()
        if let exact = names.first(where: { $0.lowercased() == query }) {
            return .send(name: exact, text: text, bang: bang)
        }
        let hits = names.filter { $0.lowercased().hasPrefix(query) }
        switch hits.count {
        case 0: return .noMatch(name)
        case 1: return .send(name: hits[0], text: text, bang: bang)
        default: return .ambiguous(hits)
        }
    }
}
