import SwiftUI

/// bob's syntax palette.
///
/// The app is dark plum glass and quiet, and code sits on a near-black wash, so
/// this stays deliberately low-contrast: comments recede, structure recedes,
/// literals warm up, and keywords borrow the accent the rest of the app already
/// uses. Five hues total. A syntax theme that reaches for a sixth colour is
/// decorating rather than helping you read.
///
/// One definition — both the transcript's fenced code and the file viewer paint
/// from here, so a colour only ever changes in one place.
enum SyntaxTheme {

    /// The colour for a token role.
    static func color(for token: SyntaxToken) -> Color {
        switch token {
        case .keyword:     return .accentColor.opacity(0.92)
        case .string:      return warm
        case .number:      return cool
        case .comment:     return .secondary.opacity(0.5)
        case .type:        return soft
        case .function:    return bright
        case .variable:    return .primary.opacity(0.86)
        case .punctuation: return .primary.opacity(0.45)
        case .plain:       return plain
        }
    }

    /// Unhighlighted code — matches the body colour the code blocks already use,
    /// so a language bob can't parse looks intentional rather than broken.
    static let plain = Color.primary.opacity(0.88)

    /// Literals: a muted apricot. Warm enough to read as "this is data", far
    /// short of a highlighter pen.
    private static let warm = Color(red: 0.84, green: 0.66, blue: 0.48)

    /// Numbers: desaturated teal. Cool against `warm` without shouting.
    private static let cool = Color(red: 0.58, green: 0.78, blue: 0.74)

    /// Types: lilac, sitting inside the app's plum rather than fighting it.
    private static let soft = Color(red: 0.73, green: 0.68, blue: 0.89)

    /// Call sites: a gentle periwinkle — close to `soft` on purpose, because the
    /// difference between naming a type and calling a function is a small one.
    private static let bright = Color(red: 0.66, green: 0.77, blue: 0.93)
}
