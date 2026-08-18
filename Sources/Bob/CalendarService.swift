import Foundation
import EventKit
import AppKit

/// EventKit-backed calendar service. Aggregates iCloud/Google/Exchange/local
/// calendars (whatever Calendar.app sees). Mirrors current state to
/// `~/bob/state/calendar.json` so claude can answer "what's next?" queries
/// instantly without shelling out.
///
/// `EKEventStoreChanged` is the trigger for re-querying EventKit. The minute tick
/// no longer does: it only re-derives now/next from the events already in hand,
/// and publishes only when the answer actually changed — an event beginning or
/// ending is a handful of publishes a day, not 1,440. The "in 12m" countdown a
/// tile shows advances in the tile, under its own `TimelineView`, rather than
/// invalidating the window from down here.
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    enum Authorization: String, Codable {
        case notDetermined
        case denied
        case restricted
        case fullAccess
        case writeOnly
        case unknown
    }

    struct Event: Codable, Equatable, Identifiable {
        var id: String { identifier }
        let identifier: String
        let title: String
        let startDate: Date
        let endDate: Date
        let location: String?
        let url: String?
        let calendarTitle: String
        let conferenceURL: String?
    }

    /// What the tile renders. Carries no timestamp on purpose: a `Date()` stamped
    /// on every tick guarantees inequality, and an unconditional publish of an
    /// unchanged tile is a whole-window invalidation for nothing.
    struct State: Codable, Equatable {
        let authorization: Authorization
        let now: Event?
        let next: Event?
    }

    /// The disk mirror, which does want a timestamp — claude reads
    /// `calendar.json` and deserves to know how stale it is.
    private struct Snapshot: Encodable {
        let state: State
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case updatedAt }

        func encode(to encoder: Encoder) throws {
            try state.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    @Published private(set) var state: State?
    @Published private(set) var authorization: Authorization = .unknown

    private let store = EKEventStore()
    private let stateFile: URL
    private var changeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var tickerTask: Task<Void, Never>?

    /// The 7-day window as last fetched, so the minute tick can re-derive now/next
    /// without going back to EventKit.
    private var window: [Event] = []
    private var lastQuery: Date = .distantPast

    /// How stale the cached window may get before the tick pays for a re-query.
    /// A 7-day horizon does age out; a minute is just not how fast.
    private static let requeryAfter: TimeInterval = 30 * 60

    private init() {
        let stateDir = BobHome.shared.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        self.stateFile = stateDir.appendingPathComponent("calendar.json")

        loadCached()
        self.authorization = Self.currentAuthorization()

        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        // Granting calendar access in System Settings does NOT reliably post
        // EKEventStoreChanged, so a denied tile would stay denied until the next
        // launch. Coming back to bob is the moment that matters — and `roll()`
        // starts with the authorization check, which is cheap.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.roll() }
        }

        // Tick every 60s so an event that has just begun or just ended moves from
        // `next` to `now` to gone. Not an EventKit query, and not a disk write.
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.roll()
            }
        }

        if authorization == .fullAccess {
            Task { await refresh() }
        }
    }

    deinit {
        for obs in [changeObserver, activationObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(obs)
        }
        tickerTask?.cancel()
    }

    private static func currentAuthorization() -> Authorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .fullAccess:    return .fullAccess
        case .writeOnly:     return .writeOnly
        @unknown default:    return .unknown
        }
    }

    /// Trigger the macOS Calendar permission prompt. Called from the UI on
    /// first user interaction — don't auto-call on app launch.
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorization = granted ? .fullAccess : .denied
            if granted {
                await refresh()
            } else {
                adopt(State(authorization: authorization, now: nil, next: nil), toDisk: true)
            }
        } catch {
            authorization = .denied
            adopt(State(authorization: .denied, now: nil, next: nil), toDisk: true)
        }
    }

    func refresh() async {
        let granted = Self.currentAuthorization()
        if granted != authorization { authorization = granted }
        guard granted == .fullAccess else {
            window = []
            adopt(State(authorization: granted, now: nil, next: nil), toDisk: true)
            return
        }

        let calendar = Calendar.current
        let now = Date()
        // Look 7 days ahead so "next event" can find tomorrow's etc.
        let lookAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: lookAhead, calendars: nil)

        window = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .map(mapEvent)
        lastQuery = now
        adopt(derived(at: now), toDisk: true)
    }

    /// The minute tick: whose turn is it now, given the window we already have.
    /// Costs nothing when the answer hasn't changed, which is almost always.
    ///
    /// Authorization is rechecked *before* the access guard, not after it. The
    /// other way round is a one-way door: a tile that went denied would keep
    /// early-returning on `authorization`, never ask the system again, and stay
    /// denied for the life of the process even after the user granted access.
    /// The check is a cheap system call; the EventKit query behind it stays gated.
    private func roll() async {
        let granted = Self.currentAuthorization()
        if granted != authorization {
            await refresh()             // adopts the new authorization, queries if it can
            return
        }
        guard granted == .fullAccess else { return }
        if Date().timeIntervalSince(lastQuery) > Self.requeryAfter {
            await refresh()
            return
        }
        adopt(derived(at: Date()), toDisk: false)
    }

    private func derived(at now: Date) -> State {
        State(
            authorization: authorization,
            now: window.first { $0.startDate <= now && $0.endDate > now },
            next: window.first { $0.startDate > now }
        )
    }

    /// `toDisk` forces a write even when nothing changed, so `calendar.json`'s
    /// timestamp still tells claude when we last actually asked EventKit.
    private func adopt(_ new: State, toDisk: Bool) {
        let changed = new != state
        if changed { state = new }
        if changed || toDisk { writeState(new) }
    }

    private func mapEvent(_ e: EKEvent) -> Event {
        Event(
            identifier: e.calendarItemIdentifier,
            title: e.title ?? "(no title)",
            startDate: e.startDate,
            endDate: e.endDate,
            location: e.location,
            url: e.url?.absoluteString,
            calendarTitle: e.calendar?.title ?? "",
            conferenceURL: Self.extractConferenceURL(from: e)
        )
    }

    // MARK: conference link extraction

    private static func extractConferenceURL(from event: EKEvent) -> String? {
        if let u = event.url?.absoluteString, isConferenceURL(u) { return u }
        if let notes = event.notes, let m = findConferenceURL(in: notes) { return m }
        if let loc = event.location, let m = findConferenceURL(in: loc) { return m }
        return nil
    }

    private static func isConferenceURL(_ s: String) -> Bool {
        s.contains("zoom.us") ||
        s.contains("meet.google.com") ||
        s.contains("teams.microsoft.com") ||
        s.contains("webex.com") ||
        s.contains("whereby.com")
    }

    private static let conferencePatterns: [String] = [
        #"https?://[a-z0-9.-]*zoom\.us/[^\s)>\]]+"#,
        #"https?://meet\.google\.com/[a-z0-9-]+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join/[^\s)>\]]+"#,
        #"https?://[a-z0-9.-]*webex\.com/[^\s)>\]]+"#,
        #"https?://whereby\.com/[a-z0-9-]+"#,
    ]

    private static func findConferenceURL(in text: String) -> String? {
        for pattern in conferencePatterns {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(text[range])
            }
        }
        return nil
    }

    // MARK: state file

    private func writeState(_ state: State) {
        StateMirror.write(Snapshot(state: state, updatedAt: Date()), to: stateFile)
    }

    private func loadCached() {
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode(State.self, from: data) {
            self.state = cached
            self.authorization = cached.authorization
        }
    }
}
