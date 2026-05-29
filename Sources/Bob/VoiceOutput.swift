import Foundation
import AVFoundation

/// bob's voice. Not the flat VoiceOver default — picks the best installed
/// English voice (premium → enhanced → whatever's there) and shapes it by the
/// hour: a touch slower and lower past midnight to match the coral "still up"
/// mood, brighter by day. Speaks sentence-by-sentence as bob streams, so it
/// sounds like thinking out loud, not reading a finished wall of text.
@MainActor
final class VoiceOutput: ObservableObject {
    @Published var enabled: Bool = false

    private let synth = AVSpeechSynthesizer()

    /// Best available English voice, resolved once. Premium/enhanced voices are
    /// downloaded on demand by the user; we gracefully fall back.
    private lazy var preferredVoice: AVSpeechSynthesisVoice? = {
        let en = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let premium = en.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = en.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Queue a sentence to speak. AVSpeechSynthesizer plays queued utterances
    /// back-to-back, so streaming sentences in gives a natural cadence.
    func speakSentence(_ raw: String) {
        guard enabled else { return }
        let text = Self.stripMarkdown(raw)
        guard !text.isEmpty else { return }

        let u = AVSpeechUtterance(string: text)
        u.voice = preferredVoice
        let night = Circadian.isNight()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * (night ? 0.94 : 1.0)
        u.pitchMultiplier = night ? 0.96 : 1.02
        u.preUtteranceDelay = night ? 0.12 : 0.05
        u.postUtteranceDelay = 0.02
        synth.speak(u)
    }

    /// One-shot: stop whatever's queued and speak this whole text.
    func speak(_ text: String) {
        stop()
        speakSentence(text)
    }

    func stop() {
        if synth.isSpeaking || synth.isPaused {
            synth.stopSpeaking(at: .immediate)
        }
    }

    // MARK: markdown → speakable text

    static func stripMarkdown(_ s: String) -> String {
        var t = s
        func sub(_ pattern: String, _ repl: String) {
            t = t.replacingOccurrences(of: pattern, with: repl, options: .regularExpression)
        }
        sub("```[\\s\\S]*?```", "")          // fenced code blocks — drop entirely
        sub("`([^`]*)`", "$1")               // inline code
        sub("\\*\\*([^*]+)\\*\\*", "$1")     // bold
        sub("\\*([^*]+)\\*", "$1")           // italic
        sub("__([^_]+)__", "$1")             // bold (underscore)
        sub("\\[([^\\]]+)\\]\\([^)]+\\)", "$1") // links → label
        sub("(?m)^#+\\s*", "")               // headers
        sub("(?m)^[-*]\\s+", "")             // bullets
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
