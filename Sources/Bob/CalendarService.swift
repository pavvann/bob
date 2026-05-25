import Foundation
import EventKit
import AppKit

/// EventKit-backed calendar service. Aggregates iCloud/Google/Exchange/local
/// calendars (whatever Calendar.app sees). Refreshes on `EKEventStoreChanged`
/// notifications + a 60s timer for countdown updates. Mirrors current state to
/// `~/bob/state/calendar.json` so claude can answer "what's next?" queries
/// instantly without shelling out.
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

    struct State: Codable, Equatable {
        let authorization: Authorization
        let now: Event?
        let next: Event?
        let updatedAt: Date
    }

    @Published private(set) var state: State?
    @Published private(set) var authorization: Authorization = .unknown

    private let store = EKEventStore()
    private let stateFile: URL
    private var changeObserver: NSObjectProtocol?
    private var tickerTask: Task<Void, Never>?

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

        // Tick every 60s so the "in 12m" / "ends in 5m" countdowns advance
        // without needing a separate timer in the view.
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await self?.refresh()
            }
        }

        if authorization == .fullAccess {
            Task { await refresh() }
        }
    }

    deinit {
        if let obs = changeObserver {
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
                writeState()
            }
        } catch {
            authorization = .denied
            writeState()
        }
    }

    func refresh() async {
        authorization = Self.currentAuthorization()
        guard authorization == .fullAccess else {
            writeState()
            return
        }

        let calendar = Calendar.current
        let now = Date()
        // Look 7 days ahead so "next event" can find tomorrow's etc.
        let lookAhead = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86400)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: lookAhead, calendars: nil)

        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        let currentEK = events.first { $0.startDate <= now && $0.endDate > now }
        let nextEK = events.first { $0.startDate > now }

        let newState = State(
            authorization: authorization,
            now: currentEK.map(mapEvent),
            next: nextEK.map(mapEvent),
            updatedAt: Date()
        )
        self.state = newState
        writeState()
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

    private func writeState() {
        let snapshot = State(
            authorization: authorization,
            now: state?.now,
            next: state?.next,
            updatedAt: Date()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            // best effort
        }
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
