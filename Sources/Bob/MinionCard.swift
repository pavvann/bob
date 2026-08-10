import SwiftUI

/// The strip of little agent cards under centerstage — bob's own minions plus
/// any external claude code sessions running in terminal tabs. Scrolls
/// sideways when the row outgrows its box. Hover lifts a card (the HoverTile
/// spring); click floats its live panel.
struct MinionStrip: View {
    let minions: [MinionService.Minion]
    let sessions: [SessionWatcher.Session]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(minions) { MinionCard(minion: $0) }
                ForEach(sessions) { SessionCard(session: $0) }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
    }
}

struct MinionCard: View {
    let minion: MinionService.Minion
    @ObservedObject private var service = MinionService.shared
    @State private var hover = false

    private var events: [MinionService.Event] { service.events(for: minion.id) }

    var body: some View {
        Button {
            SessionPanelController.shared.toggle(.minion(minion))
        } label: {
            HStack(spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(minion.task)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    subtitle
                }
                if hover {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
        .overlay { Capsule(style: .continuous).stroke(Color.white.opacity(hover ? 0.18 : 0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 7, x: 0, y: 3)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if minion.status == "working" {
            if let latest = events.last(where: { !$0.isThought }) ?? events.last {
                // show what the minion is doing RIGHT NOW
                Text(latest.text)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let start = minion.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("working · \(elapsed(from: start, to: ctx.date))")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineLimit(1)
                }
            }
        } else if let detail = minion.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    @ViewBuilder
    private var statusDot: some View {
        switch minion.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.85))
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
        case "queued":
            Circle()
                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 7, height: 7)
        default: // working
            PulseDot(color: .accentColor)
        }
    }
}

/// An external claude code session — someone else's hands, running in a
/// terminal tab. Same capsule as a minion card, marked with a terminal glyph.
struct SessionCard: View {
    let session: SessionWatcher.Session
    @State private var hover = false

    var body: some View {
        Button {
            SessionPanelController.shared.toggle(.external(session))
        } label: {
            HStack(spacing: 8) {
                PulseDot(color: .green)
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                    if let title = session.title {
                        Text(title)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 180, alignment: .leading)
                    }
                }
                if hover {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .padding(.leading, 2)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { Capsule(style: .continuous).fill(.ultraThinMaterial) }
        .overlay { Capsule(style: .continuous).stroke(Color.white.opacity(hover ? 0.18 : 0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(hover ? 0.22 : 0), radius: 7, x: 0, y: 3)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { isHover in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { hover = isHover }
        }
    }
}

/// The little breathing dot that means "alive right now".
struct PulseDot: View {
    let color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.9))
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.0 : 0.5)
            .opacity(pulse ? 1.0 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
