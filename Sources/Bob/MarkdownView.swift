import SwiftUI

/// Claude writes markdown — tables, fenced code, lists, bold. Bob was drawing it
/// as raw text, so a comparison table arrived as `| Item | Decision |` and a
/// verdict as `**Fix**`, which is precisely the work a terminal saves you.
///
/// This is a small block renderer, not a CommonMark implementation: the blocks
/// that actually show up in conversation, with inline emphasis delegated to
/// Foundation's own markdown parser. Anything it doesn't recognize falls through
/// as a paragraph, so unknown syntax degrades to readable text rather than
/// vanishing.
enum Markdown {

    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([Item])
        case numbered([Item])
        case code(language: String?, body: String)
        case table(head: [String], rows: [[String]])
        case quote(String)
        case rule
    }

    struct Item: Equatable {
        let depth: Int
        let text: String
        var marker: String? = nil
    }

    // MARK: - parsing

    static func parse(_ raw: String) -> [Block] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0

        func flush() {
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence swallows everything to its close — code is literal, and a
            // `#` or `|` inside it is code, not markup. An unclosed fence (a
            // reply still streaming) renders what has arrived so far.
            if let language = fence(trimmed) {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, fence(lines[i].trimmingCharacters(in: .whitespaces)) == nil {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    body: body.joined(separator: "\n")))
                continue
            }

            // A table is a pipe row whose next line is the dashed delimiter —
            // that second line is what separates a real table from prose that
            // happens to contain a pipe.
            if trimmed.hasPrefix("|"), i + 1 < lines.count, isDelimiter(lines[i + 1]) {
                flush()
                let head = cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    var cs = cells(row)
                    // ragged rows are common in generated tables; pad or clip so
                    // the grid stays rectangular
                    if cs.count < head.count { cs += Array(repeating: "", count: head.count - cs.count) }
                    if cs.count > head.count { cs = Array(cs.prefix(head.count)) }
                    rows.append(cs)
                    i += 1
                }
                blocks.append(.table(head: head, rows: rows))
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(hashes)
                if hashes <= 6, rest.hasPrefix(" ") {
                    flush()
                    blocks.append(.heading(level: hashes,
                                           text: String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }

            if bullet(line) != nil {
                flush()
                var items: [Item] = []
                while i < lines.count, let text = bullet(lines[i]) {
                    items.append(Item(depth: depth(lines[i]), text: text))
                    i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            if numbered(line) != nil {
                flush()
                var items: [Item] = []
                while i < lines.count, let found = numbered(lines[i]) {
                    items.append(Item(depth: depth(lines[i]), text: found.text, marker: found.marker))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flush()
                var body: [String] = []
                while i < lines.count {
                    let quoted = lines[i].trimmingCharacters(in: .whitespaces)
                    guard quoted.hasPrefix(">") else { break }
                    body.append(String(quoted.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    /// ``` or ~~~ with an optional language tag.
    private static func fence(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `|---|:--:|` — dashes, colons and pipes only, and at least one dash.
    private static func isDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func cells(_ row: String) -> [String] {
        var body = row
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func bullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• ", "+ "] where t.hasPrefix(marker) {
            return String(t.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> (marker: String, text: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        let digits = t.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = t.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(digits) + ".", String(rest.dropFirst(2)))
    }

    private static func depth(_ line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return min(2, spaces / 2)
    }

    // MARK: - inline

    /// Emphasis, code spans and links, via Foundation's parser — then the two
    /// things SwiftUI won't do on its own: code runs get a monospaced face and a
    /// faint wash, links get the accent.
    static func inline(_ text: String, codeSize: CGFloat) -> AttributedString {
        var attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: text,
                options: .init(allowsExtendedAttributes: true,
                               interpretedSyntax: .inlineOnlyPreservingWhitespace,
                               failurePolicy: .returnPartiallyParsedIfPossible))
        } catch {
            return AttributedString(text)   // unparseable emphasis still reads as words
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: codeSize, design: .monospaced)
                attributed[run.range].foregroundColor = Color.accentColor.opacity(0.95)
                attributed[run.range].backgroundColor = Color.white.opacity(0.07)
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Color.accentColor
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

/// Renders a markdown string as bob's transcript prose.
struct MarkdownText: View {
    let text: String
    var size: CGFloat = 16
    var tint: Color = .primary.opacity(0.92)

    /// Past this, parsing every streamed token stops being free — a reply that
    /// long is a document, and plain text is a fair reading of it.
    private static let ceiling = 24_000

    var body: some View {
        if text.utf8.count > Self.ceiling {
            Text(text)
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(tint)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .paragraph(let body):
            Text(Markdown.inline(body, codeSize: size - 1.5))
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(tint)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let body):
            Text(Markdown.inline(body, codeSize: size))
                .font(.system(size: level <= 1 ? size + 4 : level == 2 ? size + 2 : size + 0.5,
                              weight: level <= 2 ? .semibold : .medium,
                              design: .rounded))
                .foregroundStyle(.primary.opacity(0.95))
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(marker: item.depth > 0 ? "◦" : "•", item: item, monospacedMarker: false)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(marker: item.marker ?? "•", item: item, monospacedMarker: true)
                }
            }

        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 3) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                // Wrapped, not side-scrolled. A horizontal ScrollView here is
                // greedy in both axes — it grows to whatever height is spare —
                // and its contents can't be verified offscreen, so long lines
                // fold instead. Monospace keeps them readable either way.
                Text(body)
                    .font(.system(size: size - 2, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(.white.opacity(0.07), lineWidth: 0.5)
                    }
            }

        case .table(let head, let rows):
            TableBlock(head: head, rows: rows, size: size, tint: tint)

        case .quote(let body):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: 2)
                Text(Markdown.inline(body, codeSize: size - 2))
                    .font(.system(size: size - 1, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.vertical, 2)
        }
    }

    private func row(marker: String, item: Markdown.Item, monospacedMarker: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(marker)
                .font(.system(size: size - 3,
                              weight: .medium,
                              design: monospacedMarker ? .monospaced : .rounded))
                .foregroundStyle(.secondary.opacity(0.55))
                .frame(minWidth: monospacedMarker ? 16 : 8, alignment: .trailing)
            Text(Markdown.inline(item.text, codeSize: size - 1.5))
                .font(.system(size: size, weight: .regular, design: .rounded))
                .foregroundStyle(tint)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(item.depth) * 16)
    }
}

/// A pipe table as an actual grid. Cells wrap rather than scroll — bob's stage
/// is a fixed column, and a sentence in a cell is the normal case here, so
/// wrapping keeps the comparison readable instead of pushing it offscreen.
private struct TableBlock: View {
    let head: [String]
    let rows: [[String]]
    let size: CGFloat
    let tint: Color

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(head.indices, id: \.self) { column in
                    cell(head[column], weight: .semibold, color: .primary.opacity(0.9))
                }
            }
            .background(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5)
            }
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(head.indices, id: \.self) { column in
                        cell(index < rows.count && column < rows[index].count ? rows[index][column] : "",
                             weight: .regular, color: tint)
                    }
                }
                .background(alignment: .bottom) {
                    if index < rows.count - 1 {
                        Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 0.5)
                }
        }
    }

    private func cell(_ text: String, weight: Font.Weight, color: Color) -> some View {
        Text(Markdown.inline(text, codeSize: size - 3.5))
            .font(.system(size: size - 2, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .lineSpacing(2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
