import SwiftUI

/// The `/` palette — a compact glass sheet floating just above the input bar,
/// listing the slash commands that match what's typed. CenterStage owns all
/// the state (filter, selection, dismissal); this view draws rows and reports
/// clicks. Six rows visible, the rest scroll.
struct SlashPalette: View {
    let matches: [SlashCommand]
    let selected: Int
    let onPick: (SlashCommand) -> Void

    private let rowHeight: CGFloat = 30
    private let maxVisible = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { i, cmd in
                        row(cmd, highlighted: i == selected)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(cmd) }
                            .id(cmd.id)
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(matches.count), CGFloat(maxVisible)) * rowHeight + 12)
            .scrollIndicators(.never)
            .onChange(of: selected) { _, i in
                guard matches.indices.contains(i) else { return }
                proxy.scrollTo(matches[i].id)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private func row(_ cmd: SlashCommand, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Text("/" + cmd.name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(highlighted ? 0.95 : 0.8))
                .lineLimit(1)
            if !cmd.detail.isEmpty {
                Text(cmd.detail)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Text(cmd.source.rawValue)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.35))
                .textCase(.uppercase)
                .tracking(0.6)
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
    }
}
