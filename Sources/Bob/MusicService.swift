import Foundation
import AppKit

/// Listens for now-playing changes from Music.app and Spotify via
/// `DistributedNotificationCenter`. Fetches album artwork from the
/// unauthenticated iTunes Search API. Mirrors current state to
/// `~/bob/state/music.json` so claude can read it on-demand.
@MainActor
final class MusicService: ObservableObject {
    static let shared = MusicService()

    struct Track: Codable, Equatable {
        let name: String
        let artist: String
        let album: String
        let durationMs: Double?
        let artworkURL: URL?

        enum CodingKeys: String, CodingKey {
            case name, artist, album
            case durationMs = "duration_ms"
            case artworkURL = "artwork_url"
        }
    }

    struct Playback: Codable, Equatable {
        let source: String         // "apple_music" | "spotify"
        let state: String          // "playing" | "paused" | "stopped"
        let track: Track?
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case source, state, track
            case updatedAt = "updated_at"
        }
    }

    @Published private(set) var current: Playback? = nil

    private let stateFile: URL
    private var artworkCache: [String: URL] = [:]

    private init() {
        let root = BobHome.shared.root
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        self.stateFile = stateDir.appendingPathComponent("music.json")

        let nc = DistributedNotificationCenter.default()
        nc.addObserver(
            self,
            selector: #selector(handleAppleMusic(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleSpotify(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: notification handlers

    @objc private func handleAppleMusic(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let stateRaw = (info["Player State"] as? String) ?? "Stopped"
        let state = stateRaw.lowercased()

        guard state != "stopped" else {
            Task { @MainActor in
                self.current = Playback(source: "apple_music", state: "stopped", track: nil, updatedAt: Date())
                self.writeState()
            }
            return
        }

        let name = (info["Name"] as? String) ?? "unknown track"
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        let duration = info["Total Time"] as? Double

        Task { @MainActor in
            let art = await self.lookupArtwork(artist: artist, album: album, track: name)
            let track = Track(name: name, artist: artist, album: album, durationMs: duration, artworkURL: art)
            self.current = Playback(source: "apple_music", state: state, track: track, updatedAt: Date())
            self.writeState()
        }
    }

    @objc private func handleSpotify(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let stateRaw = (info["Player State"] as? String) ?? "Stopped"
        let state = stateRaw.lowercased()

        guard state != "stopped" else {
            Task { @MainActor in
                self.current = Playback(source: "spotify", state: "stopped", track: nil, updatedAt: Date())
                self.writeState()
            }
            return
        }

        let name = (info["Name"] as? String) ?? "unknown track"
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""
        // Spotify reports duration in seconds (sometimes ms — clamp later if needed).
        let duration: Double? = {
            if let n = info["Duration"] as? Double { return n * 1000 }
            return nil
        }()

        // Spotify sometimes ships an artwork URL directly in userInfo.
        let directArt: URL? = (info["Artwork URL"] as? String).flatMap(URL.init(string:))

        Task { @MainActor in
            let art: URL?
            if let direct = directArt {
                art = direct
            } else {
                art = await self.lookupArtwork(artist: artist, album: album, track: name)
            }
            let track = Track(name: name, artist: artist, album: album, durationMs: duration, artworkURL: art)
            self.current = Playback(source: "spotify", state: state, track: track, updatedAt: Date())
            self.writeState()
        }
    }

    // MARK: artwork lookup

    /// iTunes Search API — unauthenticated, ~20 req/min. Caches by `artist::album`.
    private func lookupArtwork(artist: String, album: String, track: String) async -> URL? {
        let key = "\(artist)::\(album)"
        if let hit = artworkCache[key] { return hit }

        let query = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        let fallback = [artist, track].filter { !$0.isEmpty }.joined(separator: " ")
        let term = (query.isEmpty ? fallback : query)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !term.isEmpty,
              let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=1")
        else { return nil }

        struct Response: Decodable {
            struct Item: Decodable { let artworkUrl100: String? }
            let results: [Item]
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            let resp = try JSONDecoder().decode(Response.self, from: data)
            if let raw = resp.results.first?.artworkUrl100 {
                // Standard iTunes trick: swap 100x100 for any size you want.
                let upscaled = raw.replacingOccurrences(of: "100x100", with: "512x512")
                if let final = URL(string: upscaled) {
                    artworkCache[key] = final
                    return final
                }
            }
        } catch {
            // Network failure / parse failure — tile renders without artwork.
        }
        return nil
    }

    // MARK: state file

    private func writeState() {
        guard let playback = current else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(playback)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            // ignore — best effort
        }
    }
}
