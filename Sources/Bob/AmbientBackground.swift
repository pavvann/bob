import SwiftUI

/// The light bob lives in. Two layers of slow, blurred, drifting color:
///  - a baseline "hour wash" from `Circadian` that's always there — cool before
///    dawn, gold mid-morning, amber-rose at golden hour, ember-indigo past
///    midnight — so the idle window is never dead air; it breathes with the room.
///  - the album-art palette layered on top when music plays, richer and brighter.
/// Both drift on a slow loop; the baseline updates through the day; the music
/// layer crossfades in and out as tracks start and stop.
struct AmbientBackground: View {
    let palette: [Color]
    let active: Bool

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 90)) { context in
            let baseline = Circadian.wash(context.date)
            GeometryReader { geo in
                ZStack {
                    // always-present hour wash
                    BlobField(colors: baseline, size: geo.size, seed: 0, opacity: 0.32)
                    // album-art wash over it when playing
                    BlobField(colors: palette, size: geo.size, seed: 2, opacity: 0.55)
                        .opacity(active && !palette.isEmpty ? 1 : 0)
                        .animation(.easeInOut(duration: 1.6), value: active)
                        .animation(.easeInOut(duration: 1.6), value: palette)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blur(radius: 105)
                .clipped()
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 3.0), value: baseline)
        }
    }
}

/// A field of slowly-drifting blurred color circles for one palette.
private struct BlobField: View {
    let colors: [Color]
    let size: CGSize
    let seed: Int
    let opacity: Double

    @State private var drift = false

    var body: some View {
        ZStack {
            ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { idx, color in
                Circle()
                    .fill(color)
                    .frame(width: size.width * 0.82, height: size.width * 0.82)
                    .position(basePosition(idx))
                    .offset(
                        x: drift ? vector(idx).dx : -vector(idx).dx,
                        y: drift ? vector(idx).dy : -vector(idx).dy
                    )
                    .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 17).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func basePosition(_ idx: Int) -> CGPoint {
        let spots: [(CGFloat, CGFloat)] = [
            (0.24, 0.28), (0.79, 0.24), (0.30, 0.80), (0.74, 0.76),
        ]
        let (fx, fy) = spots[(idx + seed) % spots.count]
        return CGPoint(x: size.width * fx, y: size.height * fy)
    }

    private func vector(_ idx: Int) -> (dx: CGFloat, dy: CGFloat) {
        let vectors: [(CGFloat, CGFloat)] = [
            (52, -34), (-44, 42), (40, 48), (-50, -32),
        ]
        let (dx, dy) = vectors[(idx + seed) % vectors.count]
        return (dx, dy)
    }
}
