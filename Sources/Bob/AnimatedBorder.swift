import SwiftUI

/// A comet-style accent that orbits the border of a rounded rectangle.
/// The stroke sits directly on the same path as the background fill (no inset
/// or radius reduction) so the curve matches the rounded shape underneath —
/// avoiding the corner artefact where an offset stroke drifts away from the
/// continuous curve. Brightest at the head, fades into a transparent tail; a
/// blurred glow under the leading edge gives the head visual heft.
struct AnimatedBorder: View {
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 2.0
    var trailLength: Double = 0.30      // fraction of perimeter
    var period: Double = 7.5             // seconds per lap
    var segments: Int = 60

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let head = (t / period).truncatingRemainder(dividingBy: 1.0)

            Canvas { ctx, size in
                let rect = CGRect(origin: .zero, size: size)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

                // 1) Faint ambient ring — always visible.
                ctx.stroke(path, with: .color(.blue.opacity(0.08)), lineWidth: 0.5)

                // 2) Blurred glow under the leading edge of the trail.
                ctx.drawLayer { glow in
                    glow.addFilter(.blur(radius: 7))
                    let span = trailLength * 0.30
                    let tail = (head - span + 1.0).truncatingRemainder(dividingBy: 1.0)
                    glow.stroke(
                        Self.subPath(of: path, from: tail, to: head),
                        with: .color(.blue.opacity(0.65)),
                        style: StrokeStyle(lineWidth: lineWidth + 6, lineCap: .round)
                    )
                }

                // 3) Fading trail — many tiny butting segments, opacity ramps to head.
                for i in 0..<segments {
                    let f0 = Double(i)     / Double(segments)
                    let f1 = Double(i + 1) / Double(segments)
                    let behind0 = trailLength * (1.0 - f0)
                    let behind1 = trailLength * (1.0 - f1)
                    let segStart = (head - behind0 + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let segEnd   = (head - behind1 + 1.0).truncatingRemainder(dividingBy: 1.0)

                    let opacity = pow(f1, 1.8)
                    let color = Color(
                        red:   0.45 + 0.30 * opacity,
                        green: 0.78 + 0.15 * opacity,
                        blue:  1.0
                    ).opacity(opacity * 0.95)

                    ctx.stroke(
                        Self.subPath(of: path, from: segStart, to: segEnd),
                        with: .color(color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt)
                    )
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Sub-path of `path` from `from` to `to`, splitting at the 1→0 seam when needed.
    private static func subPath(of path: Path, from: Double, to: Double) -> Path {
        if from == to { return Path() }
        if to > from {
            return path.trimmedPath(from: from, to: to)
        }
        var p = path.trimmedPath(from: from, to: 1.0)
        p.addPath(path.trimmedPath(from: 0.0, to: to))
        return p
    }
}
