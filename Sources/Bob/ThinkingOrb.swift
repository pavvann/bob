import SwiftUI

/// The held beat before bob's first word — a single small dot that quietly
/// breathes where the reply will appear. No halo, no spin, no bright blaze:
/// just a soft cursor of presence that the streaming text replaces.
struct ThinkingOrb: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 2.4)
            Circle()
                .fill(Color.secondary.opacity(0.28 + 0.42 * breath))
                .frame(width: 7, height: 7)
        }
        .frame(width: 7, height: 7)
    }
}
