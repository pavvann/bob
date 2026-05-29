import SwiftUI

/// A comet of light that orbits the input bar — and *reacts*. It hears your
/// voice (the trail thickens and quickens the instant you speak), it breathes
/// while bob is replying, it speeds with bob's pulse, and its color glides
/// through the day via `Circadian` (bob's blue by morning, amber at golden
/// hour, coral ember past midnight). The glow is clipped to the *outside* of
/// the path so it radiates outward and never bleeds into the bar; the canvas
/// is `bleed` larger so the blur isn't clipped at the corners.
struct AnimatedBorder: View {
    let cornerRadius: CGFloat
    var bleed: CGFloat = 14

    /// Live mic amplitude 0...1 while listening — the comet leans toward you.
    var voiceLevel: Double = 0
    /// True while bob is streaming a reply — drives a slow exhale pulse.
    var streaming: Bool = false
    /// bob's pulse 0...1 — sets the resting lap speed.
    var energy: Double = 0
    /// Optional hard color override; default follows the hour.
    var tintOverride: Color? = nil

    var lineWidth: CGFloat = 2.0
    var trailLength: Double = 0.30
    var segments: Int = 60

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let accent = tintOverride ?? Circadian.accent(timeline.date)

            // What the comet is "feeling": your voice if you're talking, else a
            // gentle sine exhale while bob replies, else calm.
            let exhale = streaming ? (0.30 + 0.30 * (0.5 + 0.5 * sin(t * 2.0))) : 0
            let drive = max(voiceLevel, exhale)

            // Resting lap speed from bob's pulse, shortened further as you speak.
            let restPeriod = BobPulse.shared.borderPeriod * (energy > 0 ? 1 : 1) // energy already folded in
            let period = lerpD(max(restPeriod, 3.8), 3.0, voiceLevel)
            let head = (t / period).truncatingRemainder(dividingBy: 1.0)

            let lw = lineWidth * (0.7 + drive * 1.9)
            let glowBlur = 7.0 * (1 + drive * 0.9)
            let glowWidth = lw + 8 + drive * 6

            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: bleed, dy: bleed)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

                // ambient ring — always faintly present, brightens as bob listens
                ctx.stroke(path, with: .color(accent.opacity(0.08 + drive * 0.12)), lineWidth: 0.5)

                // soft outer glow, clipped outside the path
                ctx.drawLayer { glow in
                    glow.clip(to: path, options: .inverse)
                    glow.addFilter(.blur(radius: glowBlur))
                    let span = trailLength * 0.30
                    let tail = (head - span + 1.0).truncatingRemainder(dividingBy: 1.0)
                    glow.stroke(
                        Self.subPath(of: path, from: tail, to: head),
                        with: .color(accent.opacity(0.55 + drive * 0.35)),
                        style: StrokeStyle(lineWidth: glowWidth, lineCap: .round)
                    )
                }

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
