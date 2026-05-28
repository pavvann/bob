import SwiftUI

/// A tile that grows on hover (Dock-style). The compact view sits at the top
/// of the row; on hover the tile expands downward, lifts with a shadow, and
/// swaps to its richer `expanded` content. zIndex puts the hovered tile
/// over its neighbors so the growth doesn't get clipped.
///
/// The HStack's `.frame(height:)` constrains layout to the compact size — the
/// hovered tile overflows downward into the area below the strip, which is
/// fine since the centerstage just gets briefly covered while you're hovering.
struct HoverTile<Content: View>: View {
    let title: String
    /// Closure that receives the current hover state so tile contents can
    /// render their compact vs expanded variants from one place.
    let content: (Bool) -> Content

    @State private var hover = false

    private var compactHeight: CGFloat { 110 }
    private var expandedHeight: CGFloat { 230 }

    var body: some View {
        Tile(title: title) {
            content(hover)
        }
        .frame(height: hover ? expandedHeight : compactHeight, alignment: .top)
        .shadow(color: .black.opacity(hover ? 0.3 : 0), radius: hover ? 16 : 0, x: 0, y: 6)
        .zIndex(hover ? 10 : 0)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                hover = isHover
            }
        }
    }
}
