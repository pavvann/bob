import SwiftUI

/// When music is playing, washes the whole window with the album art's
/// dominant colors — soft, blurred, slowly drifting blobs. Fades in when a
/// track starts, out when it stops. Sits above the desktop blur, below the
/// content.
struct AmbientBackground: View {
    let palette: [Color]
    let active: Bool

    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(palette.prefix(4).enumerated()), id: \.offset) { idx, color in
                    Circle()
                        .fill(color)
                        .frame(width: geo.size.width * 0.85, height: geo.size.width * 0.85)
                        .position(basePosition(idx, in: geo.size))
                        .offset(
                            x: drift ? driftVector(idx).dx : -driftVector(idx).dx,
                            y: drift ? driftVector(idx).dy : -driftVector(idx).dy
                        )
                        .opacity(0.55)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blur(radius: 110)
            .clipped()
        }
        .ignoresSafeArea()
        .opacity(active && !palette.isEmpty ? 1 : 0)
        .animation(.easeInOut(duration: 1.6), value: active)
        .animation(.easeInOut(duration: 1.6), value: palette)
        .onAppear {
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }

    private func basePosition(_ idx: Int, in size: CGSize) -> CGPoint {
        let spots: [(CGFloat, CGFloat)] = [
            (0.25, 0.30), (0.78, 0.25), (0.30, 0.78), (0.75, 0.75),
        ]
        let (fx, fy) = spots[idx % spots.count]
        return CGPoint(x: size.width * fx, y: size.height * fy)
    }

    private func driftVector(_ idx: Int) -> (dx: CGFloat, dy: CGFloat) {
        let vectors: [(CGFloat, CGFloat)] = [
            (50, -34), (-42, 40), (38, 46), (-48, -30),
        ]
        let (dx, dy) = vectors[idx % vectors.count]
        return (dx, dy)
    }
}
