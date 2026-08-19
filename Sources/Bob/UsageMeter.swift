import AppKit
import Foundation
import SwiftUI

// MARK: - the service

/// How much of the Claude subscription is spent. The numbers are global — one
/// account, one five-hour block, one week — so there is exactly one of these and
/// exactly one place in the window that shows it. A copy per session would be
/// four copies of the same truth, drifting.
///
/// The source is the same OAuth usage endpoint the CLI's own statusline reads.
/// bob borrows the CLI's token to ask; it never refreshes it, never stores it,
/// never logs it. A 401 means the CLI has rotated it since — so the answer is to
/// say nothing and re-read the credentials next cycle, not to hold a stale number
/// on screen.
@MainActor
final class UsageMeter: ObservableObject {
    static let shared = UsageMeter()

    /// What the strip renders. Carries no freshness timestamp on purpose: a
    /// `Date()` in here would make every snapshot compare unequal, so a poll
    /// that found nothing new would still invalidate the window. The "resets in"
    /// countdown is derived in a leaf view from `fiveHourResetsAt`, which only
    /// moves when the block actually rolls.
    struct RateLimits: Equatable {
        var fiveHourPct: Double?
        var fiveHourResetsAt: Date?
        var weekPct: Double?
        var weekResetsAt: Date?
        /// The wire's own flag — the endpoint doesn't carry it, so it survives a
        /// poll and only a later `rate_limit_event` clears it.
        var isUsingOverage = false

        /// Nothing worth drawing. The strip hides itself rather than showing
        /// em-dashes: a row of placeholders reads as a bug, absence reads as
        /// "bob hasn't asked yet".
        var isEmpty: Bool { fiveHourPct == nil && weekPct == nil }
    }

    @Published private(set) var limits = RateLimits()

    /// Ten minutes. The five-hour block moves ~0.3% a minute at full tilt, so a
    /// tighter loop would spend main-actor publishes to move a rounded integer
    /// that hadn't changed. Activation and the wire event cover the rest.
    private static let pollInterval: UInt64 = 10 * 60 * 1_000_000_000
    /// A wire event says the numbers just moved, but the CLI emits one per turn
    /// on a busy afternoon — so a nudge is worth at most one extra fetch a
    /// minute. Anything less is a poll wearing an event's clothes.
    private static let nudgeFloor: TimeInterval = 60

    private var poller: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    /// One request at a time — activation and the loop can land together, and
    /// two fetches would only race to publish the same snapshot.
    private var fetching = false
    /// A trigger that arrived while `fetching` was true. The in-flight request
    /// may predate whatever it was telling us about, so it owes one more pass.
    private var pendingRefresh = false
    private var lastNudge: Date = .distantPast

    private init() {
        // Coming back to bob is when you look at the numbers, so that's when
        // they're worth re-reading — a window that's been hidden for an hour
        // shows an hour-old block otherwise.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        poller?.cancel()
    }

    /// A `rate_limit_event` came off a session's stdout. It carries the reset
    /// instant and the overage flag first-hand, so those land immediately; the
    /// percentages still have to come from the endpoint, and that fetch is
    /// coalesced so a chatty afternoon can't turn this into a poll.
    func nudge(type: String?, resetsAt: Date?, isUsingOverage: Bool) {
        var next = limits
        next.isUsingOverage = isUsingOverage
        if let resetsAt {
            switch type {
            case "five_hour", "session", .none:
                next.fiveHourResetsAt = resetsAt
            case "seven_day", "weekly", "weekly_all":
                next.weekResetsAt = resetsAt
            default:
                break                       // a window bob doesn't show
            }
        }
        if next != limits { limits = next }

        let now = Date()
        guard now.timeIntervalSince(lastNudge) >= Self.nudgeFloor else { return }
        lastNudge = now
        Task { await refresh() }
    }

    /// Ask the endpoint. Everything expensive — reading the credential, the
    /// request, the JSON — happens off the main actor in `fetch()`; what crosses
    /// back is one ==-guarded publish.
    ///
    /// Single-flight, but never at the cost of dropping a trigger: a request
    /// already in the air may have LEFT before whatever moved the numbers, so
    /// its answer cannot be allowed to stand as the last word. A trigger that
    /// lands mid-flight is remembered and runs one more pass the moment this one
    /// finishes — sequentially, so there are still never two requests out at
    /// once. Without this, a nudge arriving during a fetch spent its 60s
    /// allowance on a reply that predated the change, and the strip stayed stale
    /// until the ten-minute poll.
    func refresh() async {
        guard !fetching else {
            pendingRefresh = true
            return
        }
        fetching = true
        defer { fetching = false }
        repeat {
            // cleared before the pass, not after: a trigger arriving *during*
            // the pass has to earn another one
            pendingRefresh = false
            await fetchOnce()
        } while pendingRefresh
    }

    private func fetchOnce() async {
        guard var fetched = await Self.fetch() else {
            // no credential, offline, or a token the CLI has since rotated.
            // Empty, not stale: a percentage bob can't vouch for is worse than
            // no percentage. The next cycle re-reads the credential fresh.
            if !limits.isEmpty { limits = RateLimits() }
            return
        }
        // the endpoint has no overage field — that fact only ever arrives on the
        // wire, so a poll must not erase it
        fetched.isUsingOverage = limits.isUsingOverage
        if fetched != limits { limits = fetched }
    }

    // MARK: - off the main actor

    /// Nonisolated and async: called from the main actor it still runs on the
    /// concurrent executor, so neither the keychain shell-out nor the request
    /// ever sits on the main thread.
    private nonisolated static func fetch() async -> RateLimits? {
        guard let token = credential(),
              let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return parse(obj)
    }

    /// `{"five_hour":{"utilization":44.0,"resets_at":"…"},"seven_day":{…}, …}` —
    /// verified live. Every other key in that payload (dollar caps, per-model
    /// scopes, promotional windows) is deliberately ignored: the strip is two
    /// numbers and a countdown, and a field bob doesn't draw is a field that
    /// can't break it.
    private nonisolated static func parse(_ obj: [String: Any]) -> RateLimits? {
        var out = RateLimits()
        if let five = obj["five_hour"] as? [String: Any] {
            out.fiveHourPct = five["utilization"] as? Double
            out.fiveHourResetsAt = date(five["resets_at"] as? String)
        }
        if let week = obj["seven_day"] as? [String: Any] {
            out.weekPct = week["utilization"] as? Double
            out.weekResetsAt = date(week["resets_at"] as? String)
        }
        return out.isEmpty ? nil : out
    }

    /// `2026-08-19T01:59:59.662232+00:00` — six fractional digits, which
    /// ISO8601DateFormatter parses on some OS versions and not others. Try it
    /// with fractions, then plain, then with the fraction cut out, so a
    /// formatter quirk costs the countdown and not the whole snapshot.
    /// Formatters are built per call rather than cached — this runs twice per
    /// poll, and a shared ISO8601DateFormatter would be mutable state reached
    /// from off the main actor for no gain at all.
    private nonisolated static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let parsed = plain.date(from: raw) { return parsed }
        guard let dot = raw.firstIndex(of: "."),
              let zone = raw[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
        else { return nil }
        return plain.date(from: String(raw[..<dot]) + String(raw[zone...]))
    }

    // MARK: - the CLI's token

    /// The file first, always: it's a plain read and asks nobody's permission.
    /// The keychain is the fallback for a CLI that keeps its credentials there
    /// instead — one shell-out to `security`, off the main actor, and the string
    /// dies with the request.
    private nonisolated static func credential() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let token = accessToken(in: data) {
            return token
        }
        return keychainCredential()
    }

    private nonisolated static func accessToken(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    /// `security find-generic-password -s "Claude Code-credentials" -w` prints
    /// the same JSON the file would hold. stderr goes to /dev/null: a denied or
    /// missing keychain item is an ordinary Tuesday, not something to log — and
    /// nothing about this call may ever reach a log, since the payload is a
    /// bearer token.
    private nonisolated static func keychainCredential() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return accessToken(in: data)
    }
}

// MARK: - context windows

/// How much context a model has to spend. bob shows a percentage, and a
/// percentage of the wrong denominator is worse than no percentage — so the
/// denominator lives here and nowhere else. Every tier is 200k today; the table
/// exists so that when one of them isn't, exactly one number changes.
///
/// Measured rather than guessed: fable sessions on this account run the 1M
/// window — one thread sat at 426k, and another read 44% on the CLI's own
/// meter while holding ~440k, both impossible at 200k. The CLI never names
/// the window on the wire (the id is `claude-fable-5` or the bare alias,
/// no `[1m]` marker), so fable's row says 1M outright. If a 200k fable ever
/// appears, its meter reads low — the honest direction to be wrong in.
enum ContextWindow {
    static let fallback = 200_000

    /// Ordered, not a dictionary: a model id containing two tier words must
    /// resolve the same way every time.
    private static let tiers: [(name: String, window: Int)] = [
        ("opus", 200_000),
        ("sonnet", 200_000),
        ("haiku", 200_000),
        ("fable", 1_000_000),
    ]

    /// The suffix a long-context variant carries when the id has one at all —
    /// `claude-opus-5[1m]`. Checked separately from the tier table because it
    /// changes the window without changing the word the caption shows.
    private static let longContextMarker = "[1m]"

    /// Model names reach bob two ways — the dial hands over a bare alias
    /// (`opus`), the CLI's init line hands over a resolved id
    /// (`claude-opus-5`, `claude-haiku-4-5-20251001`). Match on the tier word
    /// and both work.
    private static func tier(for model: String?) -> (name: String, window: Int)? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        return tiers.first { model.contains($0.name) }
    }

    static func size(for model: String?) -> Int {
        if let model, model.lowercased().contains(longContextMarker) { return 1_000_000 }
        return tier(for: model)?.window ?? fallback
    }

    /// "opus" out of "claude-opus-5" — what the caption says. nil for a model bob
    /// has no word for, so the caption shows the context number alone rather than
    /// a dated id nobody reads.
    static func shortName(for model: String?) -> String? { tier(for: model)?.name }
}

// MARK: - the tinted percentage

/// One percentage, tinted by how close it is to its ceiling. The ramp lives here
/// and nowhere else, so a colour means the same thing in the global strip and in
/// a session's own caption.
private struct MeterPercent: View {
    var label: String? = nil
    let pct: Double

    var body: some View {
        Text(label.map { "\($0) \(rounded)%" } ?? "\(rounded)%")
            .foregroundStyle(Self.tint(pct))
            .monospacedDigit()
    }

    private var rounded: Int { Int(pct.rounded()) }

    /// Tempered, not alarming: these sit in a quiet caption, so they're the
    /// palette's greens and reds at the same weight as the text around them.
    static func tint(_ pct: Double) -> Color {
        if pct >= 80 { return .red.opacity(0.85) }
        if pct >= 50 { return .orange.opacity(0.85) }
        return .green.opacity(0.85)
    }
}

/// The interpunct between fields, dimmer than either side.
private struct MeterDot: View {
    var body: some View {
        Text("·").foregroundStyle(.secondary.opacity(0.35))
    }
}

/// "resets 2h41m" — the only thing in the strip that needs a clock, and it owns
/// one. The meter publishes when the numbers change, not when the minute does;
/// a service that ticked for this would invalidate the window 1,440 times a day
/// to move one character.
private struct ResetsIn: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            Text("resets \(Self.remaining(from: ctx.date, to: date))")
                .foregroundStyle(.secondary.opacity(0.7))
                .monospacedDigit()
        }
    }

    /// "2h41m" / "41m" / "now".
    static func remaining(from now: Date, to end: Date) -> String {
        let minutes = Int(end.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "now" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h\(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - the global strip

/// The subscription in one line, always in the same corner — on bob's own stage
/// and on a session page alike. It floats over the ambient band beside the
/// memory toggle rather than sitting in the row, so the tiles keep every point
/// of width they had.
struct RateLimitStrip: View {
    @ObservedObject private var meter = UsageMeter.shared

    var body: some View {
        let limits = meter.limits
        if !limits.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "hourglass")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.5))
                if let five = limits.fiveHourPct {
                    MeterPercent(pct: five)
                }
                if let resets = limits.fiveHourResetsAt {
                    MeterDot()
                    ResetsIn(date: resets)
                }
                if let week = limits.weekPct {
                    MeterDot()
                    MeterPercent(label: "week", pct: week)
                }
                if limits.isUsingOverage {
                    MeterDot()
                    Text("overage").foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            // it's a readout, not a control — hovering it must still reach the
            // tile underneath
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - the per-session caption

/// `opus · ctx 42%` — the two things that are true of this conversation and no
/// other, in a hairline under its input bar. Silent until the first turn reports
/// usage: a context meter reading 0% before you've said anything is noise, and a
/// model name with nothing beside it isn't worth the line.
struct SessionMeterCaption: View {
    @ObservedObject var session: ClaudeSession

    var body: some View {
        if let ctx = session.contextUsedPct {
            HStack(spacing: 5) {
                if let model = session.modelShortName {
                    Text(model).foregroundStyle(.secondary.opacity(0.7))
                    MeterDot()
                }
                MeterPercent(label: "ctx", pct: ctx)
            }
            .font(.system(size: 11, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .transition(.opacity)
        }
    }
}
