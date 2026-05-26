import SwiftUI

/// The conversational tile: streaming response area + input bar with the
/// comet-border. Extracted from ContentView so the dashboard can place it
/// alongside ambient tiles.
struct TalkTileContent: View {
    @ObservedObject var bridge: ClaudeBridge
    @ObservedObject var voiceIn: VoiceInput
    @ObservedObject var voiceOut: VoiceOutput
    @ObservedObject var home: BobHome

    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            responseArea
            inputBar
        }
        .onAppear { inputFocused = true }
        .onChange(of: voiceIn.transcript) { _, newValue in
            input = newValue
        }
        .onChange(of: bridge.isStreaming) { wasStreaming, nowStreaming in
            if wasStreaming && !nowStreaming {
                voiceOut.speak(bridge.response)
            }
        }
    }

    // MARK: response

    private var responseArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if bridge.response.isEmpty && !bridge.isStreaming {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(emptyHeadline)
                                .font(.system(size: 18, weight: .light, design: .rounded))
                                .foregroundStyle(.secondary.opacity(0.7))
                            if home.status == .ready, let note = home.welcomeNote {
                                Text(note)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .lineSpacing(2)
                            }
                        }
                        .padding(.top, 2)
                    } else {
                        Text(bridge.response)
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.92))
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("response-end")
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: bridge.response) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("response-end", anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $input,
                prompt: Text(placeholder).foregroundStyle(.secondary.opacity(0.65)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .focused($inputFocused)
            .lineLimit(1...3)
            .onSubmit(send)
            .submitLabel(.send)

            micButton
            speakerButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            // Border canvas extends 14px beyond the input bar in every
            // direction so blur can radiate outward without being clipped at
            // the canvas's rectangular bounds (the source of the "squared
            // corners" artefact). The glow layer inside AnimatedBorder is
            // clipped to outside-the-path so it never bleeds into the bar.
            AnimatedBorder(cornerRadius: 22, bleed: 14)
                .padding(-14)
        }
    }

    private var micButton: some View {
        Button(action: toggleVoice) {
            ZStack {
                Circle()
                    .fill(voiceIn.isRecording ? Color.accentColor.opacity(0.18) : Color.clear)
                    .frame(width: 22, height: 22)
                Image(systemName: voiceIn.isRecording ? "waveform" : "mic")
                    .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(voiceOut.enabled ? "bob speaks responses" : "bob is silent")
    }

    // MARK: behaviour

    private var placeholder: String {
        if case .bootstrapping(let msg) = home.status { return msg }
        if case .failed(let err) = home.status { return err }
        if bridge.isStreaming { return "..." }
        if voiceIn.isRecording { return "listening..." }
        if let status = voiceIn.status { return status }
        return "talk to bob"
    }

    private var emptyHeadline: String {
        switch home.status {
        case .checking, .bootstrapping:
            return "getting to know your machine..."
        case .failed:
            return "couldn't set up ~/bob/"
        case .ready:
            return "hey."
        }
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
