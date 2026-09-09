import SwiftUI

/// One of the ambient tiles across the top: compact by default, and taller while
/// the pointer is on it so the richer variant has somewhere to go.
///
/// On a session page the same tile shrinks to nothing but its icon. The ambient
/// stuff is bob's furniture — while you're reading a session it should be within
/// reach without holding 110pt of the window hostage — and hovering an icon puts
/// the whole tile back, floating over the transcript rather than shoving it down.
struct HoverTile<Content: View>: View {
    let title: String
    /// Closure that receives the current hover state so tile contents can
    /// render their compact vs expanded variants from one place.
    let content: (Bool) -> Content
    /// Collapsed to an icon (a session is on stage), or laid out in full (bob is).
    var iconified: Bool = false
    /// Which way the revealed tile hangs off its icon.
    var reveal: Reveal = .leading

    /// The row is centred, so a tile that always opened rightward would drift
    /// further from the icon that owns it the further right that icon sits — and
    /// the eye pairs a panel with whichever icon it is nearest. Opening on the
    /// icon's own side keeps the two read as one thing, and keeps a 300pt panel
    /// off the window edges without any clamping.
    enum Reveal { case leading, center, trailing }

    /// Spelled out rather than memberwise: with two defaulted arguments sitting
    /// after `content` in declaration order, a trailing closure can no longer
    /// reach it, and the call sites read worse for it.
    init(
        title: String,
        iconified: Bool = false,
        reveal: Reveal = .leading,
        @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.title = title
        self.iconified = iconified
        self.reveal = reveal
        self.content = content
    }

    @State private var hover = false

    private var compactHeight: CGFloat { 110 }
    private var expandedHeight: CGFloat { 230 }

    /// The glyph the collapsed row shows. Unknown titles fall back to a dot
    /// rather than a blank space, so a new tile is visible before it's styled.
    private var symbol: String {
        switch title {
        case "work":     return "briefcase"
        case "music":    return "music.note"
        case "todos":    return "checklist"
        case "calendar": return "calendar"
        case "weather":  return "cloud.sun"
        default:         return "circle.dotted"
        }
    }

    var body: some View {
        if iconified { icon } else { full }
    }

    private var full: some View {
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

    /// A 30pt circle in the band's own language — the same shape as the home and
    /// surface chips, because it's the same kind of thing: a small thing you point
    /// at to get a bigger one.
    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary.opacity(hover ? 0.9 : 0.5))
            .frame(width: 30, height: 30)
            .background {
                Circle().fill(.ultraThinMaterial)
                    .overlay { if hover { Circle().fill(Color.accentColor.opacity(0.08)) } }
            }
            .overlay {
                Circle().stroke(.white.opacity(hover ? 0.16 : 0.06), lineWidth: 0.5)
            }
            .scaleEffect(hover ? 1.06 : 1)
            .contentShape(Circle())
            // The revealed tile hangs off the icon rather than living in the row,
            // so nothing below it moves — and it stays in the hover region, so
            // travelling from icon to tile doesn't dismiss it.
            .overlay(alignment: revealAlignment) {
                if hover {
                    Tile(title: title) { content(true) }
                        // hugs its content: a tile with one line in it shouldn't
                        // hang 220pt of empty glass over the transcript
                        .frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 8)
                        .offset(x: revealOffset, y: 34)
                        // grows out of the corner it is anchored to, so the
                        // motion reads as coming from the icon rather than
                        // arriving from somewhere else
                        .transition(.opacity.combined(
                            with: .scale(scale: 0.97, anchor: revealAnchor)))
                }
            }
            .zIndex(hover ? 20 : 0)
            .onHover { isHover in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    hover = isHover
                }
            }
            .help(title)
    }

    private var revealAlignment: Alignment {
        switch reveal {
        case .leading:  return .topLeading
        case .center:   return .top
        case .trailing: return .topTrailing
        }
    }

    /// A few points of overhang past the icon, outward on the side it opens to,
    /// so the panel's edge does not sit exactly on the 30pt circle's.
    private var revealOffset: CGFloat {
        switch reveal {
        case .leading:  return -6
        case .center:   return 0
        case .trailing: return 6
        }
    }

    private var revealAnchor: UnitPoint {
        switch reveal {
        case .leading:  return .topLeading
        case .center:   return .top
        case .trailing: return .topTrailing
        }
    }
}
