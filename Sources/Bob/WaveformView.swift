import SwiftUI

/// The input bar's "throat" — while you hold to talk, the text field gives way
/// to a live waveform of your actual voice, rippling in real time off the mic.
/// You're not filling a box, you're feeding something that's visibly hearing
/// you. Bars are mirrored top/bottom and tinted by the hour.
struct WaveformView: View {
    /// Rolling recent amplitudes 0...1 (oldest → newest), from VoiceInput.
    let levels: [CGFloat]

    var body: some View {
        TimelineView(.animation) { timeline in
            let accent = Circadian.accent(timeline.date)
            Canvas { ctx, size in
                let count = levels.count
                guard count > 0, size.width > 0 else { return }
                // span the full width: divide it evenly across all samples so
                // the waveform fills the box instead of hugging the right side.
                let step = size.width / CGFloat(count)
                let barWidth = max(1.5, step * 0.55)
                let midY = size.height / 2

                for (i, raw) in levels.enumerated() {
                    let lvl = max(0.04, min(1, raw))
                    // ease so quiet speech still shows life, loud doesn't clip flat
                    let h = pow(lvl, 0.75) * (size.height * 0.9)
                    let x = CGFloat(i) * step + (step - barWidth) / 2
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    let freshness = Double(i) / Double(count)
                    let op = 0.3 + 0.55 * freshness
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(accent.opacity(op))
                    )
                }
            }
        }
    }
}
