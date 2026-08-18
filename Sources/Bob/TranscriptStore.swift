import Foundation
import Observation

// MARK: - the transcript, split off the session's published surface (P2b)

/// One row of a conversation. A reference type on purpose: completed rows
/// never mutate, and the single in-flight reply grows in place — with
/// Observation, a view reading `text` invalidates on that row alone, so a
/// streamed token costs one row's body, not the window's.
@MainActor
@Observable
final class TranscriptEntry: Identifiable {
    let id = UUID()
    let role: ClaudeSession.Role
    fileprivate(set) var text: String
    let hidden: Bool                        // injected prompts (debriefs) — never rendered
    /// Live tool line ("reading Foo.swift") while this row is in flight.
    fileprivate(set) var activity: String?
    /// Non-nil on a background-task notice: live status for one task,
    /// rewritten in place and swept once it settles (ClaudeSession.noteTask).
    let taskId: String?
    /// The reply's markdown, parsed exactly once as it arrives — bob rows
    /// only, nothing else renders markdown. Fed by the store's writes; a row
    /// born with text (restored history) parses complete at birth, which is
    /// what spares /resume a re-parse of every row per frame.
    let render: MarkdownRenderModel?

    init(role: ClaudeSession.Role, text: String, hidden: Bool = false, taskId: String? = nil) {
        self.role = role
        self.text = text
        self.hidden = hidden
        self.taskId = taskId
        render = role == .bob ? MarkdownRenderModel(text: text) : nil
    }
}

/// Message content, owned by ClaudeSession but published on its own axis
/// (plan D1 revised). The session's objectWillChange now speaks only at
/// boundaries — state, question, agents — and everything per-flush lands
/// here instead. All mutation goes through the store so `revision`, the beat
/// the scroll-follow leaf and the live panel key on, can never miss a write.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var entries: [TranscriptEntry] = []
    /// Bumped by every mutation, growing text included. Appends also touch
    /// `entries`; a tail-text flush touches only its entry and this.
    private(set) var revision = 0

    func append(_ entry: TranscriptEntry) {
        entries.append(entry)
        revision += 1
    }

    func replaceAll(_ new: [TranscriptEntry]) {
        entries = new
        revision += 1
    }

    func remove(_ entry: TranscriptEntry) {
        entries.removeAll { $0 === entry }
        revision += 1
    }

    func append(text: String, to entry: TranscriptEntry) {
        entry.text += text
        entry.render?.append(text)
        revision += 1
    }

    func set(text: String, of entry: TranscriptEntry) {
        entry.text = text
        entry.render?.reset(text)
        revision += 1
    }

    /// The turn is over: the tail can't be reinterpreted any more, so the
    /// render model freezes it through the same parse a cold read would use.
    func finalize(_ entry: TranscriptEntry) {
        entry.render?.finalize()
    }

    func set(activity: String?, of entry: TranscriptEntry) {
        entry.activity = activity
        revision += 1
    }
}
