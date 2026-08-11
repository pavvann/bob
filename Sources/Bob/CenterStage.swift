import SwiftUI

/// The center of bob — the conductor. A time-aware greeting when idle, the
/// streaming response when bob's talking, and the comet-bordered input below.
/// This is where you talk to bob; the tiles are ambient periphery.
struct CenterStage: View {
    @ObservedObject var bridge: ClaudeBridge
    @ObservedObject var voiceIn: VoiceInput
    @ObservedObject var voiceOut: VoiceOutput
    @ObservedObject var home: BobHome

    /// First-name initial used in the greeting. Single letter, not identifying.
    var initialName: String = "p"

    @ObservedObject private var pulse = BobPulse.shared
    @ObservedObject private var minions = MinionService.shared
    @ObservedObject private var openLine = OpenLine.shared
    @ObservedObject private var slash = SlashCommandService.shared

    @State private var input: String = ""
    @State private var breath = PhaseClock(period: 5.2)
    @State private var slashSelection = 0
    @State private var slashDismissed = false
    @FocusState private var inputFocused: Bool

    /// The resting screen, or the thread. Notices don't count as conversation:
    /// a system whisper ("running in compatibility mode") shouldn't take over
    /// bob's face at launch — it shows in the thread the moment there's one.
    private var isIdle: Bool {
        !bridge.isStreaming && !bridge.turns.contains(where: { $0.kind != .notice })
    }

    /// Which notice rows are up — the one thing in the thread that comes and
    /// goes on its own (see the animation on the turn list).
    private var noticeRows: [UUID] {
        bridge.turns.filter { $0.kind == .notice }.map(\.id)
    }

    var body: some View {
        VStack(spacing: 24) {
            stage
            inputBar
                .overlay(alignment: .top) { slashPalette }
        }
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
                TimelineView(.animation) { timeline in
                    // breath rate follows bob's pulse — calm at rest, quicker
                    // awake. Integrated, not `t / period`: dividing absolute
                    // time by a period that moves snaps the breath mid-inhale.
                    let wave = sin(breath.tick(timeline.date, period: pulse.breathPeriod) * 2 * .pi)
                    Text(greeting)
                        .font(.system(size: 38, weight: .light, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .scaleEffect(1.0 + wave * 0.012)
                        .opacity(0.92 + wave * 0.08)
                }
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(bridge.turns) { turn in
                            turnRow(turn)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.vertical, 4)
                    // task notices are live status — they sweep themselves once
                    // the task settles. Keyed on just the notice rows so their
                    // arrival and departure fade while ordinary turns keep
                    // landing instantly.
                    .animation(.easeInOut(duration: 0.3), value: noticeRows)
                }
                // takes whatever height the window offers, up to this — tall
                // enough that a real conversation reads like a thread instead of
                // a letterbox. Bottom-anchored, so the newest turn always sits
                // right above the input bar however short the exchange is.
                .frame(maxHeight: 520)
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.never)
                .onChange(of: bridge.turns) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    /// One turn in the running conversation. Your turns sit right-aligned and
    /// muted (an echo of what you said); bob's replies are left, full reading
    /// weight; notices are a whisper the conversation flows around. Minimal —
    /// a thread, not chat bubbles.
    @ViewBuilder
    private func turnRow(_ turn: ClaudeBridge.Turn) -> some View {
        switch turn.kind {
        case .you:
            HStack {
                Spacer(minLength: 48)
                Text(turn.text)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        case .bob:
            VStack(alignment: .leading, spacing: 5) {
                if turn.text.isEmpty && bridge.isStreaming {
                    // a quiet breathing dot where the reply will appear
                    ThinkingOrb()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    Text(turn.text)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .transition(.opacity)
                }
                activityLine(turn)
            }
        case .notice:
            // system aside — a background task landing, a session reconnecting,
            // the compatibility-mode fallback. Dim, small, out of the way; it
            // reads as the room talking, not as bob.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text(turn.text)
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

    /// What bob's hands are doing right now — "reading Foo.swift" — under the
    /// streaming reply. Only the in-flight turn carries one. The slot keeps its
    /// height for as long as that turn is live, so a tool starting and ending
    /// mid-reply fades in and out instead of shoving the text around; it
    /// collapses once, when the reply lands.
    @ViewBuilder
    private func activityLine(_ turn: ClaudeBridge.Turn) -> some View {
        if turn.activity != nil || isInFlight(turn) {
            Text(turn.activity ?? " ")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(turn.activity == nil ? 0 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.18), value: turn.activity)
        }
    }

    /// The turn bob is speaking into right now — the last one, while streaming.
    private func isInFlight(_ turn: ClaudeBridge.Turn) -> Bool {
        bridge.isStreaming && bridge.turns.last?.id == turn.id
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
                    // esc peels exactly one layer per press:
                    // palette → text in the box → bob mid-reply → the whole app.
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
            // canvas and the stroke can never drift out of agreement again.
            AnimatedBorder(
                cornerRadius: 26,
                voiceLevel: Double(voiceIn.level),
                energy: pulse.energy
            )
        }
        .animation(.easeInOut(duration: 0.25), value: voiceIn.isRecording)
        .animation(.easeInOut(duration: 0.2), value: bridge.activeLens)
    }

    /// The mode bob is in, if any — `@music`, `@project:lootgo`. Sits just left
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
        return slash.matches(q)
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

    /// Splits a leading `@<token>` off a message: `("music", "play something")`.
    /// Nil when the message doesn't start with one.
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
