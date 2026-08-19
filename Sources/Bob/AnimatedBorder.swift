import AppKit
import SwiftUI

/// A comet of light that orbits the input bar — and *reacts*. It hears your
/// voice (the trail thickens and quickens the instant you speak), it speeds
/// with bob's pulse, and its color glides through the day via `Circadian`
/// (bob's blue by morning, amber at golden hour, coral ember past midnight).
///
/// One thin line, always — no glow, no bloom. The lap is a Core Animation
/// rotation of a conic gradient (the tail), clipped to the bar's outline by a
/// stroke mask: the render server runs it alone, zero per-frame main-thread
/// work. Tempo and thickness land as layer-speed and line-width writes, and
/// CA's implicit easing makes them glide. The rotation is keyframed to uniform
/// arc length (see `pacedLap`) — spun at constant angular rate the head all
/// but stopped mid-edge on a bar this wide. It pauses whenever the window
/// isn't on glass.
struct AnimatedBorder: View {
    let cornerRadius: CGFloat
    /// Slack around the bar so the stroke isn't clipped at its widest. The
    /// view grows by this on every side and the outline insets straight back,
    /// so the path still lands exactly on the bar.
    var bleed: CGFloat = 6

    /// Live mic amplitude 0...1 while listening — the comet leans toward you.
    var voiceLevel: Double = 0
    /// bob's pulse 0...1 — the single input that sets the resting lap speed.
    var energy: Double = 0
    /// Optional hard color override; default follows the hour.
    var tintOverride: Color? = nil

    var lineWidth: CGFloat = 2.0
    var trailLength: Double = 0.30

    @Environment(\.windowActivity) private var activity

    var body: some View {
        // periodic, not .animation: this clock exists only so Circadian's tint
        // keeps up with the day — the lap itself never re-enters this body.
        TimelineView(.periodic(from: .now, by: 90)) { context in
            CometSurface(
                cornerRadius: cornerRadius,
                bleed: bleed,
                accent: tintOverride ?? Circadian.accent(context.date),
                // Resting lap period from bob's pulse, shortened as you speak.
                period: lerpD(max(BobPulse.borderPeriod(at: energy), 3.8), 3.0, voiceLevel),
                drive: max(0, min(1, voiceLevel)),
                lineWidth: lineWidth,
                trailLength: trailLength,
                paused: !activity.isVisible
            )
        }
        .padding(-bleed)
        .allowsHitTesting(false)
    }

    private func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * max(0, min(1, t))
    }
}

private struct CometSurface: NSViewRepresentable {
    let cornerRadius: CGFloat
    let bleed: CGFloat
    let accent: Color
    let period: Double
    let drive: Double
    let lineWidth: CGFloat
    let trailLength: Double
    let paused: Bool

    func makeNSView(context: Context) -> CometView {
        let view = CometView()
        view.configure(cornerRadius: cornerRadius, bleed: bleed, trailLength: trailLength)
        return view
    }

    func updateNSView(_ view: CometView, context: Context) {
        view.apply(accent: accent, period: period, drive: drive,
                   baseLineWidth: lineWidth, paused: paused)
    }
}

/// The layer sandwich: a fixed container masked to the bar's outline (a stroke
/// as wide as the comet), holding a big rotating square of conic gradient —
/// the tail. The mask lives on the container, not the gradient: a mask rides
/// its own layer's transform, and the outline must hold still while the tail
/// spins. The ambient ring is its own thin stroke alongside.
final class CometView: NSView {
    private let ring = CAShapeLayer()
    private let cometClip = CALayer()
    private let cometMask = CAShapeLayer()
    private let tail = CAGradientLayer()

    private var cornerRadius: CGFloat = 0
    private var bleed: CGFloat = 0
    private var trailLength: Double = 0.30
    private var lastAccent: Color?
    private var lastDrive: Double = -1
    /// The size the lap keyframes were computed for, and the layer-local time
    /// the lap notionally started — so a resize re-keys the pacing without
    /// teleporting the head.
    private var lapSize: CGSize = .zero
    private var lapEpoch: CFTimeInterval = 0

    /// The lap the spin is authored at; real tempo is a speed multiplier on
    /// the layer, so it can change without restarting the animation.
    private static let basePeriod: Double = 13

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tail.type = .conic
        tail.startPoint = CGPoint(x: 0.5, y: 0.5)
        tail.endPoint = CGPoint(x: 1.0, y: 0.5)
        cometMask.fillColor = nil
        cometMask.strokeColor = NSColor.white.cgColor
        cometMask.lineCap = .butt
        cometClip.mask = cometMask
        cometClip.addSublayer(tail)
        ring.fillColor = nil
        ring.lineWidth = 0.5
        layer?.addSublayer(cometClip)
        layer?.addSublayer(ring)
        // no spin here: the keyframes need real bounds, so layout starts it
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// The border is decoration over the input bar — never eat a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(cornerRadius: CGFloat, bleed: CGFloat, trailLength: Double) {
        self.cornerRadius = cornerRadius
        self.bleed = bleed
        self.trailLength = trailLength
        needsLayout = true
    }

    func apply(accent: Color, period: Double, drive: Double, baseLineWidth: CGFloat, paused: Bool) {
        if accent != lastAccent || drive != lastDrive {
            // implicit CA animations on these are the glide
            cometMask.lineWidth = baseLineWidth * (0.7 + drive * 1.9)
            ring.strokeColor = NSColor(accent).withAlphaComponent(0.08 + drive * 0.12).cgColor
            if accent != lastAccent { retint(accent) }
            lastAccent = accent
            lastDrive = drive
        }
        setSpeed(paused ? 0 : Float(Self.basePeriod / max(period, 0.05)))
        // the system drops repeating animations now and then (offscreen,
        // backing changes) — put the lap back
        if !paused, tail.animation(forKey: "lap") == nil { spin() }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let barRect = bounds.insetBy(dx: bleed, dy: bleed)
        let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .path(in: barRect).cgPath
        cometClip.frame = bounds
        cometMask.frame = bounds
        cometMask.path = path
        ring.frame = bounds
        ring.path = path
        // the tail must cover the bar at every rotation angle: a centred
        // square as wide as the view's diagonal
        let diag = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot()
        tail.bounds = CGRect(x: 0, y: 0, width: diag, height: diag)
        tail.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = window?.backingScaleFactor ?? 2
        for l in [cometClip, cometMask, ring, tail] { l.contentsScale = scale }
        CATransaction.commit()
        if bounds.size != lapSize {
            lapSize = bounds.size
            spin()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func spin() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // resume mid-flight: a respin (resize, dropped animation) must not
        // teleport the head, so the phase rides the layer's own clock
        let local = tail.convertTime(CACurrentMediaTime(), from: nil)
        let phase = ((local - lapEpoch) / Self.basePeriod)
            .truncatingRemainder(dividingBy: 1)
        lapEpoch = local - phase * Self.basePeriod
        let (values, keyTimes) = pacedLap()
        let lap = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lap.values = values
        lap.keyTimes = keyTimes
        lap.calculationMode = .linear
        lap.duration = Self.basePeriod
        lap.repeatCount = .infinity
        lap.isRemovedOnCompletion = false
        lap.timeOffset = phase * Self.basePeriod
        tail.add(lap, forKey: "lap")
    }

    /// Keyframes that hold the head at constant speed along the outline. A
    /// conic gradient spun at constant angular rate is arc-length-uniform only
    /// on a circle; on a bar this wide the head crawled through the long
    /// edges' middles and sprinted around the ends. Sampling the outline at
    /// uniform arc length and keying the rotation to each sample's
    /// angle-from-center makes the render server hold perimeter speed
    /// instead. The tail still spans a fixed slice of the conic, so its drawn
    /// length breathes a little with position — the one residual.
    private func pacedLap() -> (values: [NSNumber], keyTimes: [NSNumber]) {
        let rect = bounds.insetBy(dx: bleed, dy: bleed)
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let cx = rect.midX, cy = rect.midY
        let (x0, x1, y0, y1) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        let quarter = r * .pi / 2
        let arc: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGPoint = { acx, acy, a0, t in
            CGPoint(x: acx + r * cos(a0 + t / r), y: acy + r * sin(a0 + t / r))
        }
        // counterclockwise from the middle of the right edge — the head's
        // authored angle, so the first keyframe is rotation zero
        let segs: [(len: CGFloat, at: (CGFloat) -> CGPoint)] = [
            (max(0, y1 - r - cy), { CGPoint(x: x1, y: cy + $0) }),
            (quarter, { arc(x1 - r, y1 - r, 0, $0) }),
            (max(0, x1 - x0 - 2 * r), { CGPoint(x: x1 - r - $0, y: y1) }),
            (quarter, { arc(x0 + r, y1 - r, .pi / 2, $0) }),
            (max(0, y1 - y0 - 2 * r), { CGPoint(x: x0, y: y1 - r - $0) }),
            (quarter, { arc(x0 + r, y0 + r, .pi, $0) }),
            (max(0, x1 - x0 - 2 * r), { CGPoint(x: x0 + r + $0, y: y0) }),
            (quarter, { arc(x1 - r, y0 + r, 3 * .pi / 2, $0) }),
            (max(0, cy - y0 - r), { CGPoint(x: x1, y: y0 + r + $0) }),
        ]
        let total = segs.reduce(CGFloat(0)) { $0 + $1.len }
        guard total > 0 else { return ([0, 2 * Double.pi as NSNumber], [0, 1]) }
        let n = 144
        var values: [NSNumber] = []
        var seg = 0
        var consumed: CGFloat = 0
        var prev = 0.0
        var offset = 0.0
        for i in 0...n {
            let s = total * CGFloat(i) / CGFloat(n)
            while seg < segs.count - 1, s - consumed > segs[seg].len {
                consumed += segs[seg].len
                seg += 1
            }
            let p = segs[seg].at(min(max(0, s - consumed), segs[seg].len))
            var a = Double(atan2(p.y - cy, p.x - cx)) + offset
            if a < prev - 0.001 {
                offset += 2 * .pi
                a += 2 * .pi
            }
            prev = a
            values.append(a as NSNumber)
        }
        values[n] = 2 * Double.pi as NSNumber
        let keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        return (values, keyTimes)
    }

    /// Change the lap tempo (or freeze it) without teleporting the phase:
    /// CAMediaTiming maps parent time through `speed`, so a bare speed write
    /// jumps the animation — re-anchor local time first.
    private func setSpeed(_ speed: Float) {
        guard tail.speed != speed else { return }
        let now = CACurrentMediaTime()
        let local = tail.convertTime(now, from: nil)
        tail.speed = speed
        tail.timeOffset = local
        tail.beginTime = speed == 0 ? 0 : now
    }

    /// The tail: clear for most of the lap, rising to the accent at the head —
    /// the old per-segment pow(f, 1.8) fade, baked into gradient stops.
    private func retint(_ accent: Color) {
        let base = NSColor(accent)
        var colors: [CGColor] = [base.withAlphaComponent(0).cgColor]
        var locations: [NSNumber] = [0]
        for f in stride(from: 0.0, through: 1.0, by: 0.25) {
            colors.append(base.withAlphaComponent(pow(f, 1.8) * 0.85).cgColor)
            locations.append(NSNumber(value: 1 - trailLength * (1 - f)))
        }
        tail.colors = colors
        tail.locations = locations
    }
}
