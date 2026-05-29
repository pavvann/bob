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

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    private var isIdle: Bool { bridge.turns.isEmpty && !bridge.isStreaming }

    var body: some View {
        VStack(spacing: 24) {
            stage
            inputBar
        }
        .onAppear {
            inputFocused = true
            refreshPulse()
            // bob speaks each sentence as it streams (no-op unless voice is on).
            bridge.onSentence = { [weak voiceOut] sentence in
                voiceOut?.speakSentence(sentence)
            }
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
                    // breath rate follows bob's pulse — calm at rest, quicker awake
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let phase = sin(t / pulse.breathPeriod * 2 * .pi)
                    Text(greeting)
                        .font(.system(size: 38, weight: .light, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.88))
                        .scaleEffect(1.0 + phase * 0.012)
                        .opacity(0.92 + phase * 0.08)
                }
                .fixedSize()
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
                }
                .frame(maxHeight: 380)
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
    /// weight. Minimal — a thread, not chat bubbles.
    @ViewBuilder
    private func turnRow(_ turn: ClaudeBridge.Turn) -> some View {
        switch turn.role {
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
            if turn.text.isEmpty && bridge.isStreaming {
                // the held breath before the first word — a living glyph, not "…"
                ThinkingOrb(size: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(turn.text)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
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
                .transition(.opacity)
            }

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
            AnimatedBorder(
                cornerRadius: 26,
                bleed: 16,
                voiceLevel: Double(voiceIn.level),
                streaming: bridge.isStreaming,
                energy: pulse.energy
            )
            .padding(-16)
        }
        .animation(.easeInOut(duration: 0.25), value: voiceIn.isRecording)
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
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        input = ""
        home.welcomeNote = nil
        voiceOut.stop()
        bridge.send(prompt)
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
