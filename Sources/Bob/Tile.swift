import SwiftUI

/// A rounded card with a small uppercased title and a content slot.
/// Used as the unit of bob's dashboard grid.
struct Tile<Content: View>: View {
    let title: String
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.55))
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.05), lineWidth: 0.5)
        }
    }
}
