import Foundation
import SwiftUI

// MARK: - the service

/// How much of the Claude subscription is spent. The numbers are global — one
/// account, one five-hour block, one week — so there is exactly one of these and
/// exactly one place in the window that shows it. A copy per session would be
/// four copies of the same truth, drifting.
///
/// **The wire is the source.** Every turn's `rate_limit_event` carries
/// `rate_limit_info.unifiedWindows` — both utilizations, both reset instants,
/// unasked.
///
/// The OAuth usage endpoint survives as the stand-in for the one case the wire
/// cannot cover: no turn has happened yet. It is asked at most once per run,
/// after a grace period, and never once the wire has spoken — which is the whole
/// reason first launch no longer opens with a keychain prompt. When it is asked,
/// bob borrows the CLI's token and never refreshes, stores or logs it.
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
        /// fetch and only a later `rate_limit_event` clears it.
        var isUsingOverage = false

        /// Nothing worth drawing. The strip hides itself rather than showing
        /// em-dashes: a row of placeholders reads as a bug, absence reads as
        /// "bob hasn't asked yet".
        var isEmpty: Bool { fiveHourPct == nil && weekPct == nil }
    }

    @Published private(set) var limits = RateLimits()

    /// Which source filled the percentages, named rather than left to be
    /// inferred. `.wire` is terminal for the life of the process. Not
    /// `@Published` — nothing draws it.
    enum Source: Equatable { case nothingYet, wire, endpoint }

    private(set) var source: Source = .nothingYet

    /// How long the wire gets before bob resorts to asking. Long enough that any
    /// real use of bob — one turn, in any session — arrives first and cancels the
    /// shot, and short enough that a window left open untouched still fills in.
    /// One sleeper, fired once, never a loop.
    private static let wireGrace: UInt64 = 90 * 1_000_000_000

    private var endpointFallback: Task<Void, Never>?
    /// The endpoint has been asked. One attempt per process — see `refresh()`.
    private var endpointAsked = false

    private init() {
        endpointFallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.wireGrace)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    deinit {
        endpointFallback?.cancel()
    }

    /// A `rate_limit_event` came off a session's stdout with the whole strip on
    /// it. No I/O here — this is arithmetic and one guarded publish.
    ///
    /// `unifiedWindows` is absent from the published SDK types, so a line without
    /// it is an ordinary outcome, not an error: it means the endpoint is wanted
    /// after all, and sooner than the grace would have allowed.
    func apply(_ info: RateLimitInfo) {
        var next = limits
        next.isUsingOverage = info.isUsingOverage
        if let resetsAt = info.resetsAt {
            switch info.type {
            case "five_hour", "session", .none:
                next.fiveHourResetsAt = resetsAt
            case "seven_day", "weekly", "weekly_all":
                next.weekResetsAt = resetsAt
            default:
                break                       // a window bob doesn't show
            }
        }
        // written after the switch, because the unified block names both windows
        // explicitly and so outranks the one `rateLimitType` picked — including
        // for the week's countdown, which the old shape supplied one turn in many
        if let pct = info.fiveHourPct { next.fiveHourPct = pct }
        if let at = info.fiveHourResetsAt { next.fiveHourResetsAt = at }
        if let pct = info.weekPct { next.weekPct = pct }
        if let at = info.weekResetsAt { next.weekResetsAt = at }
        if next != limits { limits = next }

        guard !info.hasPercentages else {
            // first-hand numbers. The endpoint has nothing left to add for the
            // life of this process, so the pending shot is cancelled outright
            // rather than left to fire and read a credential for nothing.
            source = .wire
            endpointFallback?.cancel()
            endpointFallback = nil
            return
        }
        Task { await refresh() }
    }

    /// Ask the endpoint. Everything expensive — reading the credential, the
    /// request, the JSON — happens off the main actor in `fetch()`; what crosses
    /// back is one ==-guarded publish.
    ///
    /// Two guards, and they are the whole design. **Never once the wire has
    /// spoken**, which is why a bob you talk to reads no credential at all; and
    /// **once per process**, which is why one you never talk to reads it exactly
    /// once instead of on a clock. Between them there is nothing to serialise, so
    /// the single-flight bookkeeping this used to carry went out with the poll.
    func refresh() async {
        guard source != .wire, !endpointAsked else { return }
        endpointAsked = true
        let answer = await Self.fetch()
        // a turn may have landed while the request was in the air, and a
        // first-hand number outranks a fetched one however it arrived
        guard source != .wire else { return }
        guard var fetched = answer else {
            // no credential, offline, or a token the CLI has since rotated.
            // Empty, not stale: a percentage bob can't vouch for is worse than
            // no percentage, and the next turn will say it firsthand anyway.
            if !limits.isEmpty { limits = RateLimits() }
            return
        }
        // the endpoint has no overage field — that fact only ever arrives on the
        // wire, so a fetch must not erase it
        fetched.isUsingOverage = limits.isUsingOverage
        if fetched != limits { limits = fetched }
        source = .endpoint
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
    /// verified live. Note `utilization` here is already a **percentage** (44.0),
    /// where the wire's is a fraction (0.44) — the wire's is converted at decode
    /// so both arrive in the same units. Every other key in that payload (dollar
    /// caps, per-model scopes, promotional windows) is deliberately ignored: the
    /// strip is two numbers and a countdown, and a field bob doesn't draw is a
    /// field that can't break it.
    ///
    /// Internal, not private, so a harness can hold the two mouths side by side
    /// and assert they land on the same drawn number.
    nonisolated static func parse(_ obj: [String: Any]) -> RateLimits? {
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

// MARK: - the same strip, from codex's wire

/// The codex half of the global strip — the *same* two numbers and countdown,
/// from a source that costs nothing to read.
///
/// The contrast with the meter above is the whole point. That one reads a
/// keychain, holds a bearer token, calls an HTTPS endpoint and polls every ten
/// minutes because nothing tells it when the numbers move. Codex tells bob:
/// `account/rateLimits/updated` arrives unasked on the app-server connection,
/// once a turn, for the account rather than for a thread. So there is **no
/// poller, no endpoint, no credential and no timer on this path** — one
/// subscription to `CodexServer.events`, and one RPC at the top so a codex tab
/// that hasn't spoken yet still shows numbers.
///
/// Publishes `UsageMeter.RateLimits`, not a shape of its own: the strip is one
/// component with two sources, and a second value type is how two readouts
/// start disagreeing about what 80% looks like.
@MainActor
final class CodexMeter: ObservableObject {
    static let shared = CodexMeter()

    @Published private(set) var limits = UsageMeter.RateLimits()

    /// The merged snapshot, kept whole because the pushes are sparse: an update
    /// carrying only `primary` must not erase the week.
    private var merged = CodexRateLimits()
    private var watch: Task<Void, Never>?
    /// The one-shot read has been asked for on this app-server. Re-armed when
    /// the server dies, since the next one is a different process with a
    /// different snapshot to hand over.
    private var asked = false

    private init() {}

    /// Idempotent — SessionManager opens this with the rest of the ambient layer,
    /// harnesses drive their own instance's `apply` directly.
    func start() { start(server: .shared) }

    func start(server: CodexServer) {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            // eagerly, in case the server is already up — bob calls this at
            // launch, before any codex tab exists, so this attempt normally
            // finds nothing and costs nothing
            await self?.primeOnce(server)
            for await event in await server.events {
                guard let self else { return }
                switch event {
                case .rateLimits(let update):
                    self.apply(update)
                case .serverExited:
                    // whatever comes back is a new process with its own
                    // snapshot to hand over
                    self.asked = false
                default:
                    // any account-level line at all means app-server is up and
                    // answering, which is the only thing the read was waiting
                    // for. `remoteControl/status/changed` arrives right after
                    // `initialize` (measured), so in practice this fires before
                    // the first turn — and if a future build sends nothing, the
                    // first turn's own push fills the strip anyway.
                    await self.primeOnce(server)
                }
            }
        }
    }

    /// `account/rateLimits/read` — once per app-server, never on a clock. The
    /// schema's own advice: base on the read, merge the rolling updates into it.
    ///
    /// `asked` is set only when the server actually answered. A call that threw
    /// means there is no app-server yet, and marking that as asked would be how
    /// the strip stays blank for a whole session.
    private func primeOnce(_ server: CodexServer) async {
        guard !asked else { return }
        do {
            let result = try await server.call("account/rateLimits/read", params: [:])
            asked = true
            if let snapshot = result["rateLimits"] as? [String: Any] {
                apply(CodexJSON.rateLimits(snapshot))
            }
        } catch {
            // nothing to say yet; the next account-level line asks again
        }
    }

    /// Merge, then publish only if the drawn value actually moved. Internal so a
    /// harness can drive it with fixtures instead of a live account.
    func apply(_ update: CodexRateLimits) {
        merged.merge(update)
        let next = Self.strip(merged)
        if next != limits { limits = next }
    }

    /// Codex's two windows in the strip's own words.
    ///
    /// Which window is which is read off its **duration**, not off the key:
    /// `primary`/`secondary` are 300 and 10080 minutes today, and a strip that
    /// called a window "week" because it arrived second would be wrong the day
    /// that stops being true. An absent duration falls back to the documented
    /// order, which is the only guess available.
    static func strip(_ snapshot: CodexRateLimits) -> UsageMeter.RateLimits {
        var out = UsageMeter.RateLimits()
        for (window, isPrimary) in [(snapshot.primary, true), (snapshot.secondary, false)] {
            guard let window else { continue }
            let isShort = window.windowMins.map { $0 < 24 * 60 } ?? isPrimary
            if isShort {
                out.fiveHourPct = window.usedPercent
                out.fiveHourResetsAt = window.resetsAt
            } else {
                out.weekPct = window.usedPercent
                out.weekResetsAt = window.resetsAt
            }
        }
        return out
    }
}

// MARK: - context windows

/// The tier word a model id reduces to, and the one number to divide by when
/// nothing else is available.
///
/// This used to hold a per-model window table, a `[1m]` sniffer and a ratchet,
/// because the denominator was believed to be unavailable. It is reported: every
/// `result` carries `modelUsage[<id>].contextWindow` (200000 for haiku, 1000000
/// for `claude-sonnet-5[1m]` — both captured live), and the session takes it from
/// there. The `result` that supplies the window is the same event that computes
/// the percentage, so what is left here covers only a turn that reported no
/// window at all — which is why it is one number rather than a table, and why it
/// no longer claims to know anything about any tier.
enum ContextWindow {
    static let fallback = 200_000

    /// Ordered, not a set: a model id containing two tier words must resolve the
    /// same way every time.
    private static let tiers = ["opus", "sonnet", "haiku", "fable"]

    /// "opus" out of "claude-opus-5" — what the caption says. Model names reach
    /// bob two ways, the dial's bare alias (`opus`) and the CLI's resolved id
    /// (`claude-haiku-4-5-20251001`); matching on the tier word handles both. nil
    /// for a model bob has no word for, so the caption shows the context number
    /// alone rather than a dated id nobody reads.
    static func shortName(for model: String?) -> String? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        return tiers.first { model.contains($0) }
    }
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
///
/// **It follows the active session's provider** (#38 T2.5, decision 3 of #35):
/// codex's two windows on a codex tab, the claude subscription everywhere else.
/// One component, two sources — same glyph, same threshold ramp, same countdown
/// leaf — because a second strip is how two readouts start meaning different
/// things by the same colour. Both meters are observed rather than one of them,
/// since a view cannot subscribe conditionally; each publishes only when its
/// drawn numbers move, so the idle cost of the one you aren't looking at is nil.
struct RateLimitStrip: View {
    var provider: SessionProvider = .claude

    @ObservedObject private var meter = UsageMeter.shared
    @ObservedObject private var codex = CodexMeter.shared

    /// Which source a provider draws from. A named function rather than a
    /// ternary buried in `body`, so the switch itself can be asserted without
    /// rendering anything.
    static func source(for provider: SessionProvider,
                       claude: UsageMeter.RateLimits,
                       codex: UsageMeter.RateLimits) -> UsageMeter.RateLimits {
        provider == .codex ? codex : claude
    }

    var body: some View {
        let limits = Self.source(for: provider, claude: meter.limits, codex: codex.limits)
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
///
/// Provider-agnostic by construction, and now symmetrical behind the glass:
/// codex reports `modelContextWindow` on `thread/tokenUsage/updated`, claude
/// reports `modelUsage[<id>].contextWindow` on `result`. Both denominators are
/// the provider's own number; neither is a table.
struct SessionMeterCaption<S: StageSession>: View {
    @ObservedObject var session: S

    var body: some View {
        if let ctx = session.contextUsedPct {
            HStack(spacing: 5) {
                if let model = session.modelLabel {
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
