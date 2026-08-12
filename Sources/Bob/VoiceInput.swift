import Foundation
import Speech
import AVFoundation

@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var status: String? = nil
    /// Live mic amplitude, 0...1, smoothed — drives the listening waveform + comet.
    @Published var level: CGFloat = 0
    /// A short rolling history of recent levels for a scrolling waveform.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 48)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?

    /// The current recognition request. Read from the realtime audio tap, swapped
    /// on the main actor when recognition restarts — nonisolated(unsafe) because
    /// SFSpeechAudioBufferRecognitionRequest.append is itself thread-safe and a
    /// benign one-buffer race on a swap is harmless.
    private nonisolated(unsafe) var liveRequest: SFSpeechAudioBufferRecognitionRequest?

    /// Stays true from the user pressing the mic until they press it again — so
    /// recognition restarts through natural pauses instead of ending on silence.
    private var keepListening = false
    /// Finalized text from prior recognition segments this session.
    private var committed = ""
    private var starting = false

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording, !starting else { return }
        starting = true
        transcript = ""
        committed = ""
        status = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self else { return }
                switch auth {
                case .authorized:
                    self.beginRecording()
                case .denied, .restricted, .notDetermined:
                    self.status = "speech permission not granted"
                @unknown default:
                    self.status = "speech permission unknown state"
                }
                self.starting = false
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            status = "speech recognizer unavailable"
            return
        }
        keepListening = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.liveRequest?.append(buffer)
            self?.publishLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            status = "audio engine failed: \(error.localizedDescription)"
            keepListening = false
            return
        }
        startRecognitionSegment()
    }

    /// Begin (or restart) a recognition request against the already-running
    /// engine. SFSpeechRecognizer finalizes after a pause; we just open a fresh
    /// segment so the mic keeps listening until the user stops it.
    private func startRecognitionSegment() {
        guard keepListening, let recognizer else { return }
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        liveRequest = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.keepListening else { return }
                if let result {
                    let partial = result.bestTranscription.formattedString
                    self.transcript = self.committed.isEmpty
                        ? partial
                        : (self.committed + " " + partial)
                    if result.isFinal {
                        self.committed = self.transcript
                        self.startRecognitionSegment() // keep listening through the pause
                    }
                } else if error != nil {
                    // a silence/no-speech timeout — reopen and keep waiting
                    self.startRecognitionSegment()
                }
            }
        }
    }

    func stop() {
        keepListening = false
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        liveRequest?.endAudio()
        task?.cancel()
        liveRequest = nil
        task = nil
        isRecording = false
        level = 0
        levels = Array(repeating: 0, count: 48)
    }

    /// RMS amplitude of a mic buffer, lifted into a visible 0...1 range and
    /// heavily smoothed so the comet leans in gently rather than strobing.
    private nonisolated func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        let normalized = min(1, max(0, CGFloat(rms) * 14))

        Task { @MainActor in
            // strong smoothing on the comet driver kills the per-word flicker;
            // the waveform history keeps the rawer value so bars still ripple.
            self.level = self.level * 0.82 + normalized * 0.18
            var next = self.levels
            next.removeFirst()
            next.append(normalized)
            self.levels = next
        }
    }
}
