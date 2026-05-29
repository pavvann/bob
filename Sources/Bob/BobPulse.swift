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
        withAnimation(.easeInOut(duration: 1.4)) { energy = target }
    }

    /// Comet border lap period in seconds — slow when resting, fast when racing.
    var borderPeriod: Double { lerp(13, 3.8, energy) }

    /// Breathing-greeting cycle in seconds.
    var breathPeriod: Double { lerp(5.2, 2.2, energy) }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * max(0, min(1, t))
    }
}
