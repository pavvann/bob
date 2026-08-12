import Foundation

/// A center-stage surface — what the middle of the window is showing instead of
/// the conversation. Chat isn't a case: it's the absence of one.
enum AppSurface: String, CaseIterable, Identifiable {
    case notes
    case canvas

    var id: String { rawValue }
    var label: String { rawValue }

    var symbol: String {
        switch self {
        case .notes:  return "note.text"
        case .canvas: return "rectangle.3.group"
        }
    }
}

/// One published field: which surface is up, nil for the normal chat stage.
/// Deliberately its own object rather than a field on SessionManager — a
/// surface is what the window shows, not something about bob's session, and the
/// band, the stage and the esc chain all read it without going through the
/// bridge.
@MainActor
final class SurfaceRouter: ObservableObject {
    static let shared = SurfaceRouter()

    @Published var active: AppSurface?

    private init() {}

    /// Band chips: clicking the surface you're already on drops back to chat.
    func toggle(_ surface: AppSurface) {
        active = (active == surface) ? nil : surface
    }

    /// Esc's new layer. True when there was a surface to close.
    @discardableResult
    func close() -> Bool {
        guard active != nil else { return false }
        active = nil
        return true
    }
}
