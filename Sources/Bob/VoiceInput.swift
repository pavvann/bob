import Foundation
import Speech
import AVFoundation

@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var transcript: String = ""
    @Published var status: String? = nil

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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
    }
}
