import SwiftUI

/// A comet-style accent that orbits the border of a rounded rectangle.
/// The crisp leading line sits directly on the path; the soft glow is clipped
/// to the *outside* of the path so it radiates outward and never bleeds into
/// the input bar interior. The canvas itself is `bleed` larger than the path
/// in every direction so blur has room to extend without being clipped at the
/// rectangular canvas bounds (which is what produced the "squared corners"
/// artefact previously).
///
/// Tint defaults to time-aware: cool blue during the day, warm coral red
/// between 8pm and 6am local time.
struct AnimatedBorder: View {
    let cornerRadius: CGFloat
    /// Spacing between the rounded rect path and the canvas edges. The caller
    /// should match this with `.padding(-bleed)` so the canvas extends beyond
    /// the host view, giving blur room to render outward.
    var bleed: CGFloat = 14
    var tint: Tint = .auto
    var lineWidth: CGFloat = 2.0
    var trailLength: Double = 0.30
    var period: Double = 7.5
    var segments: Int = 60

    enum Tint {
        case auto   // blue 6am–8pm, red 8pm–6am
        case blue
        case red
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let head = (t / period).truncatingRemainder(dividingBy: 1.0)
            let theme = resolveTint(at: timeline.date)

            Canvas { ctx, size in
                // Path sits `bleed` inset from canvas edges. This is where the
                // visible border curve should align with the host view's edge.
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: bleed, dy: bleed)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

                // 1) Faint ambient ring along the border.
                ctx.stroke(path, with: .color(theme.ambient), lineWidth: 0.5)

                // 2) Outer glow — clipped to OUTSIDE the path so blur radiates
                //    outward only and doesn't bleed into the host view interior.
                ctx.drawLayer { glow in
                    glow.clip(to: path, options: .inverse)
                    glow.addFilter(.blur(radius: 8))
                    let span = trailLength * 0.30
                    let tail = (head - span + 1.0).truncatingRemainder(dividingBy: 1.0)
                    glow.stroke(
                        Self.subPath(of: path, from: tail, to: head),
                        with: .color(theme.glow),
                        style: StrokeStyle(lineWidth: lineWidth + 8, lineCap: .round)
                    )
                }

                // 3) Crisp fading trail — sits exactly on the border. Not
                //    clipped, so it traces the curve cleanly on both sides
                //    of the edge.
                for i in 0..<segments {
                    let f0 = Double(i)     / Double(segments)
                    let f1 = Double(i + 1) / Double(segments)
                    let behind0 = trailLength * (1.0 - f0)
                    let behind1 = trailLength * (1.0 - f1)
                    let segStart = (head - behind0 + 1.0).truncatingRemainder(dividingBy: 1.0)
                    let segEnd   = (head - behind1 + 1.0).truncatingRemainder(dividingBy: 1.0)

                    let opacity = pow(f1, 1.8)
                    ctx.stroke(
                        Self.subPath(of: path, from: segStart, to: segEnd),
                        with: .color(theme.trailColor(opacity)),
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

    // MARK: tint

    private struct Theme {
        let ambient: Color
        let glow: Color
        let trailColor: (Double) -> Color
    }

    private func resolveTint(at date: Date) -> Theme {
        let isNight: Bool
        switch tint {
        case .red:
            isNight = true
        case .blue:
            isNight = false
        case .auto:
            let hour = Calendar.current.component(.hour, from: date)
            isNight = (hour >= 20 || hour < 6)
        }

        if isNight {
            return Theme(
                ambient: Color(red: 1.0, green: 0.30, blue: 0.35).opacity(0.10),
                glow: Color(red: 1.0, green: 0.30, blue: 0.38).opacity(0.75),
                trailColor: { opacity in
                    Color(
                        red:   1.0,
                        green: 0.32 + 0.22 * opacity,
                        blue:  0.38 + 0.22 * opacity
                    ).opacity(opacity * 0.95)
                }
            )
        } else {
            return Theme(
                ambient: Color.blue.opacity(0.08),
                glow: Color.blue.opacity(0.70),
                trailColor: { opacity in
                    Color(
                        red:   0.45 + 0.30 * opacity,
                        green: 0.78 + 0.15 * opacity,
                        blue:  1.0
                    ).opacity(opacity * 0.95)
                }
            )
        }
    }
}
