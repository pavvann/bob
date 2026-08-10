import SwiftUI

/// bob's pulse — one shared rhythm the whole app moves to, so bob's state of
/// mind is felt rather than read. Slow at rest, quicker when you're typing to
/// it, racing while it thinks or while its minions grind. The comet border and
/// the breathing greeting both derive their tempo from `energy`, so a glance
/// tells you what bob is doing without a single word or spinner.
@MainActor
final class BobPulse: ObservableObject {
    static let shared = BobPulse()

    /// 0 = at rest, 1 = racing.
    @Published var energy: Double = 0

    private init() {}

    func refresh(focused: Bool, streaming: Bool, listening: Bool, minions: Int) {
        let target: Double
        if listening {
            target = 0.9
        } else if streaming {
            target = 0.7
        } else if minions > 0 {
            target = min(1.0, 0.45 + Double(minions) * 0.18)
        } else if focused {
            target = 0.32
        } else {
            target = 0.0
        }
        guard abs(target - energy) > 0.001 else { return }
        // No `withAnimation` here: energy is read as a plain number inside
        // Canvas/TimelineView closures, which SwiftUI cannot interpolate. The
        // easing that actually lands lives in `PhaseClock`, on the render clock.
        energy = target
    }

    /// Comet border lap period in seconds — slow when resting, fast when racing.
    static func borderPeriod(at energy: Double) -> Double { lerp(13, 3.8, energy) }

    /// Breathing-greeting cycle in seconds.
    static func breathPeriod(at energy: Double) -> Double { lerp(5.2, 2.2, energy) }

    var breathPeriod: Double { Self.breathPeriod(at: energy) }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * max(0, min(1, t))
    }
}

/// A cyclic phase that is *integrated* frame to frame — `phase += dt / period`
/// — rather than derived as `t / period`. That distinction is the whole point:
/// `t` is an epoch-sized timestamp (~8e8), so nudging a mutable `period` by a
/// second moves `t / period` by millions of laps and teleports whatever it
/// drives. Integrating keeps the phase continuous however the tempo moves, and
/// the period is itself eased so a change of tempo glides instead of stepping.
///
/// Not thread-safe by design: it's ticked once per frame from a view body.
final class PhaseClock {
    /// Current position in the cycle, 0..<1.
    private(set) var phase = 0.0
    /// Eased period, chasing whatever target the last `tick` was given.
    private(set) var period: Double
    /// Seconds since the previous tick, clamped: a backgrounded `TimelineView`
    /// resumes with a huge gap and must not lurch a whole lap on the way back.
    private(set) var dt = 0.0

    private var last: Date?

    init(period: Double) { self.period = period }

    @discardableResult
    func tick(_ date: Date, period target: Double, ease tau: Double = 0.45) -> Double {
        dt = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 1.0 / 15.0)
        if last == nil { period = target }
        last = date
        period = chase(period, to: target, tau: tau)
        phase = (phase + dt / max(period, 0.05)).truncatingRemainder(dividingBy: 1)
        return phase
    }

    /// Ease any scalar toward `target` on this frame's `dt`, so the curve is the
    /// same whether we're running at 120Hz or dropping frames.
    func chase(_ value: Double, to target: Double, tau: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / max(tau, 0.001)))
    }
}
