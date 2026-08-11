import SwiftUI

/// A comet of light that orbits the input bar — and *reacts*. It hears your
/// voice (the trail thickens and quickens the instant you speak), it speeds
/// with bob's pulse, and its color glides through the day via `Circadian`
/// (bob's blue by morning, amber at golden hour, coral ember past midnight).
///
/// One thin line, always — no glow, no bloom, nothing that smears the bar while
/// bob is thinking. Every reactive quantity is integrated or eased on the render
/// clock by `CometMotion` — never read straight off `t / period`, never stepped
/// off a boolean — so submitting and toggling the mic *glide*.
struct AnimatedBorder: View {
    let cornerRadius: CGFloat
    /// Slack around the bar so the stroke isn't clipped at its widest. The
    /// canvas grows by this on every side and insets straight back, so the path
    /// still lands exactly on the bar.
    var bleed: CGFloat = 6

    /// Live mic amplitude 0...1 while listening — the comet leans toward you.
    var voiceLevel: Double = 0
    /// bob's pulse 0...1 — the single input that sets the resting lap speed.
    var energy: Double = 0
    /// Optional hard color override; default follows the hour.
    var tintOverride: Color? = nil

    var lineWidth: CGFloat = 2.0
    var trailLength: Double = 0.30
    // 26 fading sub-strokes read identically to 60 but halve the per-frame
    // trimmedPath cost.
    var segments: Int = 26

    @State private var motion = CometMotion()

    var body: some View {
        TimelineView(.animation) { timeline in
            let accent = tintOverride ?? Circadian.accent(timeline.date)
            let m = motion.advance(
                to: timeline.date,
                // Resting lap speed from bob's pulse, shortened as you speak.
                period: lerpD(max(BobPulse.borderPeriod(at: energy), 3.8), 3.0, voiceLevel),
                voice: voiceLevel
            )
            let head = m.phase
            let drive = m.drive

            let lw = lineWidth * (0.7 + drive * 1.9)

            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: bleed, dy: bleed)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

                // ambient ring — always faintly present, brightens as you speak
                ctx.stroke(path, with: .color(accent.opacity(0.08 + drive * 0.12)), lineWidth: 0.5)

                // crisp fading comet trail
                for i in 0..<segments {
                    let f0 = Double(i) / Double(segments)
                    let f1 = Double(i + 1) / Double(segments)
                    let behind0 = trailLength * (1.0 - f0)
                    let behind1 = trailLength * (1.0 - f1)
                    let segStart = (head - behind0 + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let segEnd = (head - behind1 + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let opacity = pow(f1, 1.8) * (0.85 + drive * 0.15)
                    ctx.stroke(
                        Self.subPath(of: path, from: segStart, to: segEnd),
                        with: .color(accent.opacity(opacity)),
                        style: StrokeStyle(lineWidth: lw, lineCap: .butt)
                    )
                }
            }
            .padding(-bleed)
            .allowsHitTesting(false)
        }
    }

    private func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * max(0, min(1, t))
    }

    private static func subPath(of path: Path, from: Double, to: Double) -> Path {
        if from == to { return Path() }
        if to > from { return path.trimmedPath(from: from, to: to) }
        var p = path.trimmedPath(from: from, to: 1.0)
        p.addPath(path.trimmedPath(from: 0.0, to: to))
        return p
    }
}

/// The comet's memory between frames. `phase` rides a `PhaseClock` so it stays
/// continuous while the lap period changes underneath it; `drive` (how thick and
/// bright the comet burns) is eased on the same clock, so your voice lifts and
/// releases it instead of stepping.
private final class CometMotion {
    struct Frame {
        let phase: Double
        let drive: Double
    }

    private let clock = PhaseClock(period: 13)
    private var drive = 0.0

    func advance(to date: Date, period: Double, voice: Double) -> Frame {
        clock.tick(date, period: period)
        drive = clock.chase(drive, to: voice, tau: 0.30)
        return Frame(phase: clock.phase, drive: drive)
    }
}
