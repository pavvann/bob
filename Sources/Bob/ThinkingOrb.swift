import SwiftUI

/// The held beat before bob's first word — a single small dot that quietly
/// breathes where the reply will appear. No halo, no spin, no bright blaze:
/// just a soft cursor of presence that the streaming text replaces. 30fps is
/// invisible on a 7pt dot, and it holds its breath when the window's unseen.
struct ThinkingOrb: View {
    @Environment(\.windowActivity) private var activity

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !activity.isVisible)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(t * 2.4)
            Circle()
                .fill(Color.secondary.opacity(0.28 + 0.42 * breath))
                .frame(width: 7, height: 7)
        }
        .frame(width: 7, height: 7)
    }
}
