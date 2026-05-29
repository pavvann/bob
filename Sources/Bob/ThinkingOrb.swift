import SwiftUI

/// What bob looks like in the held breath between your message and its first
/// word — three points of light orbiting a soft center, the conductor gathering
/// itself. Calm at first, quickening just before words land. Tinted by the hour
/// so it shares the app's circadian palette. Replaces the dead "…".
struct ThinkingOrb: View {
    var size: CGFloat = 26
    var diameter: CGFloat { size }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let accent = Circadian.accent(timeline.date)
            // gentle ease that quickens — the "inhale held, then a reach"
            let speed = 1.6 + 0.6 * (0.5 + 0.5 * sin(t * 0.8))
            let phase = t * speed

            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let orbit = sz.width * 0.30
                // soft core
                let coreRect = CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)
                ctx.fill(Circle().path(in: coreRect), with: .color(accent.opacity(0.35)))

                for i in 0..<3 {
                    let a = phase + Double(i) * (2 * .pi / 3)
                    let breath = 1 + 0.18 * sin(t * 1.3 + Double(i))
                    let x = c.x + cos(a) * orbit
                    let y = c.y + sin(a) * orbit * 0.92
                    let r = 2.6 * breath
                    let dot = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    // each dot is a tiny radial glow
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: 2.4))
                        layer.fill(Circle().path(in: dot.insetBy(dx: -2, dy: -2)),
                                   with: .color(accent.opacity(0.5)))
                    }
                    ctx.fill(Circle().path(in: dot), with: .color(accent.opacity(0.95)))
                }
            }
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
    }
}
