import Foundation
import WeatherKit
import CoreLocation

/// Fetches local weather via WeatherKit, using CoreLocation for the user's
/// position. Mirrors state to `~/bob/state/weather.json` so claude can answer
/// "what's the weather?" without its own lookup.
///
/// Like MusicKit, WeatherKit needs the `com.apple.developer.weatherkit`
/// entitlement — may require Developer ID signing rather than ad-hoc. Failures
/// are logged to `~/bob/state/weather-debug.log`.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    static let shared = WeatherService()

    /// What the tile renders. The freshness stamp lives on the disk mirror, not
    /// in here — the weather at 3pm and the weather at 3.30pm are usually the
    /// same tile, and a timestamp would make them compare unequal.
    struct State: Codable, Equatable {
        let temperatureC: Double
        let condition: String
        let symbolName: String
        let locationName: String
        let highC: Double?
        let lowC: Double?

        enum CodingKeys: String, CodingKey {
            case temperatureC = "temperature_c"
            case condition
            case symbolName = "symbol_name"
            case locationName = "location_name"
            case highC = "high_c"
            case lowC = "low_c"
        }
    }

    /// The `~/bob/state/weather.json` mirror claude reads.
    private struct Snapshot: Encodable {
        let state: State
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }

        func encode(to encoder: Encoder) throws {
            try state.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    @Published private(set) var state: State?
    @Published private(set) var locationStatus: CLAuthorizationStatus
    @Published private(set) var lastError: String?

    private let locationManager = CLLocationManager()
    private let weather = WeatherKit.WeatherService.shared
    private let stateFile: URL
    private var refreshTask: Task<Void, Never>?

    private override init() {
        let stateDir = BobHome.shared.root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        self.stateFile = stateDir.appendingPathComponent("weather.json")
        self.locationStatus = locationManager.authorizationStatus
        super.init()
        loadCached()
        locationManager.delegate = self

        if isAuthorized(locationStatus) {
            locationManager.requestLocation()
            startPeriodicRefresh()
        }
    }

    /// Trigger the location permission prompt — call from the tile on first click.
    func requestAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func isAuthorized(_ s: CLAuthorizationStatus) -> Bool {
        switch s {
        case .notDetermined, .denied, .restricted: return false
        default: return true  // .authorized / .authorizedAlways on macOS
        }
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000) // 30 min
                self?.locationManager.requestLocation()
            }
        }
    }

    private func fetchWeather(for location: CLLocation) async {
        do {
            let result = try await weather.weather(for: location)
            let current = result.currentWeather
            let today = result.dailyForecast.first
            let place = await Self.reverseGeocode(location)

            let newState = State(
                temperatureC: current.temperature.converted(to: .celsius).value,
                condition: current.condition.description,
                symbolName: current.symbolName,
                locationName: place,
                highC: today?.highTemperature.converted(to: .celsius).value,
                lowC: today?.lowTemperature.converted(to: .celsius).value
            )
            if newState != state { state = newState }
            if lastError != nil { lastError = nil }
            writeState(newState)
            Self.log("weather updated: \(Int(newState.temperatureC.rounded()))°C \(newState.condition) @ \(place)")
        } catch {
            let desc = String(describing: error)
            // The XPC failure to weatherkit.authservice means the app lacks the
            // WeatherKit entitlement (ad-hoc signed). Surface a clear message —
            // guarded, because an unentitled build fails every refresh forever
            // and the same string twice is not news.
            let message = desc.contains("weatherkit") || desc.contains("xpcConnectionFailed")
                ? "weatherkit needs app signing"
                : "couldn't load weather"
            if message != lastError { lastError = message }
            Self.log("WeatherKit error: \(desc)")
        }
    }

    private static func reverseGeocode(_ location: CLLocation) async -> String {
        let geocoder = CLGeocoder()
        if let placemarks = try? await geocoder.reverseGeocodeLocation(location),
           let p = placemarks.first {
            return p.locality ?? p.administrativeArea ?? p.name ?? "your location"
        }
        return "your location"
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
        }
    }

    // MARK: debug log

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob/state/weather-debug.log")
    }

    private static func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.locationManager.authorizationStatus
            self.locationStatus = status
            if self.isAuthorized(status) {
                self.locationManager.requestLocation()
                self.startPeriodicRefresh()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            await self.fetchWeather(for: last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            WeatherService.log("location error: \(error.localizedDescription)")
        }
    }
}
