import SwiftUI

/// One of the ambient tiles on bob's own stage: compact by default, and taller
/// while the pointer is on it so the richer variant has somewhere to go.
///
/// Only the full layout lives here. While a session is on stage the row collapses
/// to icons with one shared panel, and that is `AmbientBar` — an icon that
/// revealed its own tile put the card in a different place for every icon, which
/// read as unattached.
struct HoverTile<Content: View>: View {
    let title: String
    /// Receives the current hover state so a tile's contents can render their
    /// compact and expanded variants from one place.
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
