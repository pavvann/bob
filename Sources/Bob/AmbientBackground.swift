import SwiftUI

/// The light bob lives in. Two layers of soft blurred color:
///  - a baseline "hour wash" from `Circadian` that's always there — cool before
///    dawn, gold mid-morning, amber-rose at golden hour, ember-indigo past
///    midnight — so the idle window is never dead air.
///  - the album-art palette layered on top when music plays, richer and brighter.
/// The wash is a *picture*, not live geometry: anything moving under a 105pt
/// blur costs a full-window offscreen recomposite every frame, forever. So the
/// blobs and the blur are baked into a quarter-scale bitmap once per state —
/// palette, hour, size — and state changes crossfade two static images. The
/// room still shifts with the day and the music; it just never burns while
/// holding still.
struct AmbientBackground: View {
    let palette: [Color]
    let active: Bool

    var body: some View {
        // periodic, not .animation: this clock exists only to pick up
        // Circadian's 10-minute wash buckets
        TimelineView(.periodic(from: .now, by: 90)) { context in
            GeometryReader { geo in
                WashCrossfade(
                    baseline: Circadian.wash(context.date),
                    palette: active ? palette : [],
                    size: geo.size
                )
            }
            .ignoresSafeArea()
        }
    }
}

/// Double-buffered wash: render the new state into the hidden slot, then one
/// finite ease swaps which slot shows. No repeatForever anywhere.
private struct WashCrossfade: View {
    let baseline: [Color]
    let palette: [Color]
    let size: CGSize

    @State private var slotA: NSImage?
    @State private var slotB: NSImage?
    @State private var showB = false
    @State private var rendered: Key?

    private struct Key: Equatable {
        let baseline: [Color]
        let palette: [Color]
        // live-resize would re-render per frame; the wash is formless enough
        // to stretch, so only coarse size steps count as a new state
        let w: Int
        let h: Int
    }

    private var key: Key {
        Key(baseline: baseline, palette: palette,
            w: Int(size.width / 64), h: Int(size.height / 64))
    }

    var body: some View {
        ZStack {
            if let slotA { Image(nsImage: slotA).resizable().opacity(showB ? 0 : 1) }
            if let slotB { Image(nsImage: slotB).resizable().opacity(showB ? 1 : 0) }
        }
        .animation(.easeInOut(duration: 2.4), value: showB)
        .onAppear { refresh() }
        .onChange(of: key) { refresh() }
    }

    private func refresh() {
        guard key != rendered, size.width > 0, size.height > 0 else { return }
        rendered = key
        guard let image = Self.render(baseline: baseline, palette: palette, size: size) else { return }
        if slotA == nil && slotB == nil {
            slotA = image        // first paint — nothing to fade from
        } else if showB {
            slotA = image
            showB = false
        } else {
            slotB = image
            showB = true
        }
    }

    /// Quarter-scale offscreen render of the same blobs the live view used to
    /// composite, blur baked in — a one-off cost per state change.
    private static func render(baseline: [Color], palette: [Color], size: CGSize) -> NSImage? {
        let renderer = ImageRenderer(content:
            ZStack {
                BlobField(colors: baseline, seed: 0, opacity: 0.32, size: size)
                if !palette.isEmpty {
                    BlobField(colors: palette, seed: 2, opacity: 0.55, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .blur(radius: 105)
            .clipped()
        )
        renderer.scale = 0.25
        return renderer.nsImage
    }
}

/// A field of soft color circles for one palette — only ever drawn offscreen
/// through `render`, never composited live.
private struct BlobField: View {
    let colors: [Color]
    let seed: Int
    let opacity: Double
    let size: CGSize

    var body: some View {
        ZStack {
            ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { idx, color in
                Circle()
                    .fill(color)
                    .frame(width: size.width * 0.82, height: size.width * 0.82)
                    .position(basePosition(idx))
                    .opacity(opacity)
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
}
