import SwiftUI

/// Where spans turn into colour.
///
/// Both renderers paint from here: the transcript's fenced blocks want one
/// attributed string for the whole fence, the file viewer wants one per line, and
/// neither should have to learn how a span reaches an `AttributedString`.
extension AttributedString {

    /// `source`, with every span in its role's colour.
    ///
    /// Spans arrive sorted, non-overlapping and never ``SyntaxToken/plain``, so
    /// this only sets colour where a span actually exists. A gap keeps whatever
    /// the view's own foreground is — which is how code bob can't read stays the
    /// body colour instead of going grey.
    init(painting source: String, spans: [SyntaxSpan]) {
        var painted = AttributedString(source)
        for span in spans {
            guard let range = Range(span.range, in: painted) else { continue }
            painted[range].foregroundColor = SyntaxTheme.color(for: span.token)
        }
        self = painted
    }
}

extension SyntaxSpan {

    /// File-wide spans cut to a line-by-line layout.
    ///
    /// The file viewer lays out one `Text` per line, but the highlighter speaks in
    /// offsets into the whole file, so the two have to be reconciled. One walk
    /// down both lists: each span is clipped to the line it lands in and rebased
    /// to that line's own coordinates, and a span that outlives its line — a
    /// multi-line string, a block comment — is held back and clipped again on the
    /// next one.
    static func perLine(_ lines: [String], of spans: [SyntaxSpan]) -> [[SyntaxSpan]] {
        var sliced = [[SyntaxSpan]](repeating: [], count: lines.count)
        var cursor = 0
        var start = 0                       // utf-16 offset of this line's first character
        for (index, line) in lines.enumerated() {
            let end = start + line.utf16.count
            while cursor < spans.count, spans[cursor].range.location < end {
                let span = spans[cursor]
                let lower = max(span.range.location, start)
                let upper = min(span.range.upperBound, end)
                if lower < upper {
                    sliced[index].append(SyntaxSpan(range: NSRange(location: lower - start,
                                                                  length: upper - lower),
                                                    token: span.token))
                }
                guard span.range.upperBound <= end else { break }
                cursor += 1
            }
            start = end + 1                 // the newline `components(separatedBy:)` dropped
        }
        return sliced
    }
}
