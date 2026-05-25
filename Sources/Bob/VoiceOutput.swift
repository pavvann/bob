import Foundation
import AVFoundation

@MainActor
final class VoiceOutput: ObservableObject {
    @Published var enabled: Bool = false

    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        guard enabled, !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
    }
}
