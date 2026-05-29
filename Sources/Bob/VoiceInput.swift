import Foundation
import Speech
import AVFoundation

@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var status: String? = nil
    /// Live mic amplitude, 0...1, smoothed — drives the listening waveform.
    @Published var level: CGFloat = 0
    /// A short rolling history of recent levels for a scrolling waveform.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 48)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        transcript = ""
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
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            status = "speech recognizer unavailable"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.publishLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            status = "audio engine failed: \(error.localizedDescription)"
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        level = 0
        levels = Array(repeating: 0, count: 48)
    }

    /// Compute RMS amplitude of a mic buffer, map to a pleasant 0...1 curve,
    /// and push it (smoothed) to the published level + rolling history.
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
        // Mic RMS is tiny; lift into a visible range and clamp.
        let normalized = min(1, max(0, CGFloat(rms) * 14))

        Task { @MainActor in
            // Smooth so the dot/bars breathe rather than jitter.
            self.level = self.level * 0.6 + normalized * 0.4
            var next = self.levels
            next.removeFirst()
            next.append(normalized)
            self.levels = next
        }
    }
}
