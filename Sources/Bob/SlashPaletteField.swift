import SwiftUI

/// The `/` palette's state for one input bar: where the highlight rests, and
/// whether esc has closed it.
///
/// The matches themselves are never stored. `SlashCommandService` already holds
/// the assembled list in memory, so filtering it is a string pass over what's
/// there — a stored copy would buy nothing and cost a publish per keystroke.
struct SlashPaletteState: Equatable {
    var selection = 0
    /// One-shot: any edit reopens the sheet, which is what makes esc peel
    /// exactly one layer instead of turning the palette off for good.
    var dismissed = false

    /// The token being typed after a leading `/` — nil once a space is typed
    /// (you're writing arguments now), or while something else owns the box.
    /// `/` and `@` never collide: a lens starts with `@`, a command with `/`.
    static func query(in input: String, suspended: Bool = false) -> String? {
        guard !suspended, input.hasPrefix("/") else { return nil }
        let token = input.dropFirst()
        guard !token.contains(where: { $0.isWhitespace }) else { return nil }
        return String(token)
    }

    @MainActor
    func matches(for input: String, scope: SlashCommandService.Scope,
                 suspended: Bool = false) -> [SlashCommand] {
        guard !dismissed, let q = Self.query(in: input, suspended: suspended) else { return [] }
        return SlashCommandService.shared.matches(q, in: scope)
    }

    /// Selection clamped to the live match list — arrows move it, every
    /// keystroke rests it back to the top.
    func selected(of count: Int) -> Int { min(selection, max(0, count - 1)) }

    /// Put the picked name in the box, trailing space ready for arguments. The
    /// space also hides the palette, so the next Enter sends as usual.
    static func complete(_ cmd: SlashCommand, into input: inout String) {
        input = "/" + cmd.name + " "
    }

    /// Enter with the palette up completes the highlighted name; Enter on a name
    /// that's already complete returns false and the caller sends. True = the
    /// press was spent here.
    @MainActor
    mutating func completeOnEnter(_ input: inout String,
                                  scope: SlashCommandService.Scope) -> Bool {
        let rows = matches(for: input, scope: scope)
        guard !rows.isEmpty else { return false }
        let cmd = rows[selected(of: rows.count)]
        guard input.trimmingCharacters(in: .whitespaces) != "/" + cmd.name else { return false }
        Self.complete(cmd, into: &input)
        return true
    }

    /// Esc's first layer. True = the press was spent closing the sheet, so the
    /// caller's own ladder (clear the box, stop the reply, leave the tab) stays
    /// exactly one press further away.
    @MainActor
    mutating func dismissOnEscape(_ input: String,
                                  scope: SlashCommandService.Scope) -> Bool {
        guard !matches(for: input, scope: scope).isEmpty else { return false }
        dismissed = true
        return true
    }
}

extension View {
    /// The arrow and tab keys, on the **text field**.
    ///
    /// Not on the bar around it: a vertical-axis `TextField` handles up/down
    /// itself (cursor movement) and tab (focus), and an ancestor's `onKeyPress`
    /// only sees what the focused view declines — so those three would never
    /// arrive. The companion's palette hangs them off its field for the same
    /// reason. Esc and Enter stay with the caller: both are rungs on a ladder
    /// only the stage knows the rest of.
    func slashPaletteKeys(_ state: Binding<SlashPaletteState>,
                          input: Binding<String>,
                          scope: SlashCommandService.Scope) -> some View {
        modifier(SlashPaletteKeys(state: state, input: input, scope: scope))
    }

    /// The sheet, on the **input bar** — whose width it matches and whose top
    /// edge it sits 8pt above. Also where the reopen-on-edit lives, since that
    /// is about the sheet rather than about any one key.
    func slashPaletteSheet(_ state: Binding<SlashPaletteState>,
                           input: Binding<String>,
                           scope: SlashCommandService.Scope) -> some View {
        modifier(SlashPaletteSheet(state: state, input: input, scope: scope))
    }
}

private struct SlashPaletteKeys: ViewModifier {
    @Binding var state: SlashPaletteState
    @Binding var input: String
    let scope: SlashCommandService.Scope

    private var matches: [SlashCommand] { state.matches(for: input, scope: scope) }

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                let rows = matches
                guard !rows.isEmpty else { return .ignored }
                state.selection = max(0, state.selected(of: rows.count) - 1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                let rows = matches
                guard !rows.isEmpty else { return .ignored }
                state.selection = min(rows.count - 1, state.selected(of: rows.count) + 1)
                return .handled
            }
            .onKeyPress(.tab) {
                let rows = matches
                guard !rows.isEmpty else { return .ignored }
                SlashPaletteState.complete(rows[state.selected(of: rows.count)], into: &input)
                return .handled
            }
    }
}

private struct SlashPaletteSheet: ViewModifier {
    @Binding var state: SlashPaletteState
    @Binding var input: String
    let scope: SlashCommandService.Scope
    /// Observed so the sheet fills in when a background harvest lands while
    /// the palette is already open.
    @ObservedObject private var service = SlashCommandService.shared

    private var matches: [SlashCommand] { state.matches(for: input, scope: scope) }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { sheet }
            .onChange(of: input) { _, _ in
                // any edit reopens a dismissed palette and rests the highlight —
                // standard palette feel, and it makes esc's dismissal one-shot
                state.dismissed = false
                state.selection = 0
                // the harvest is throttled, and only claude's list has one: a
                // codex palette is bob's own commands and needs no disk at all
                if input.hasPrefix("/"), scope != .work(.codex) { service.refresh() }
            }
    }

    @ViewBuilder
    private var sheet: some View {
        let rows = matches
        if !rows.isEmpty {
            SlashPalette(matches: rows, selected: state.selected(of: rows.count)) { cmd in
                SlashPaletteState.complete(cmd, into: &input)
            }
            .frame(maxWidth: .infinity)
            // sit fully above the bar: this view's bottom+8 becomes its top
            .alignmentGuide(.top) { $0[.bottom] + 8 }
            .transition(.opacity)
        }
    }
}
