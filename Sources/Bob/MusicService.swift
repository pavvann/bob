import Foundation
import AppKit
import SwiftUI

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

    /// What the tile renders. No timestamp: Music.app re-announces the same track
    /// often enough that a `Date()` in here made every announcement a fresh
    /// publish, and every publish an artwork-palette recompute.
    struct Playback: Codable, Equatable {
        let source: String         // "apple_music" | "spotify"
        let state: String          // "playing" | "paused" | "stopped"
        let track: Track?

        enum CodingKeys: String, CodingKey {
            case source, state, track
        }
    }

    /// The `~/bob/state/music.json` mirror claude reads.
    private struct Snapshot: Encodable {
        let playback: Playback
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }

        func encode(to encoder: Encoder) throws {
            try playback.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(updatedAt, forKey: .updatedAt)
        }
    }

    @Published private(set) var current: Playback? = nil {
        didSet {
            let newURL = current?.track?.artworkURL
            if newURL != oldValue?.track?.artworkURL {
                Task { await updatePalette(for: newURL) }
            }
        }
    }

    /// Dominant colors pulled from the current track's artwork — drives the
    /// ambient album-art background.
    @Published private(set) var palette: [Color] = []

    /// True when something is actively playing (not paused/stopped).
    var isPlaying: Bool { current?.state == "playing" }

    /// Publish a track from outside (e.g. when MusicCatalogService plays via
    /// ApplicationMusicPlayer — Music.app's playerInfo notification doesn't
    /// fire for that, so we push directly to the tile).
    func publish(track: Track, state: String = "playing", source: String = "apple_music_catalog") {
        adopt(Playback(source: source, state: state, track: track))
    }

    /// State-only update for the in-process catalog player (pause/resume/stop
    /// from the bob://music transport deep links). No-op when something else
    /// owns the tile, so a stray catalog event can't clobber a Music.app or
    /// Spotify play.
    func publishCatalogState(_ state: String) {
        guard let cur = current, cur.source == "apple_music_catalog", cur.state != state else { return }
        adopt(Playback(source: cur.source, state: state,
                       track: state == "stopped" ? nil : cur.track))
    }

    /// The one door onto `current`: the publish is `==`-guarded, and the disk
    /// mirror is written off-main whenever the player has spoken.
    private func adopt(_ playback: Playback) {
        if playback != current { current = playback }
        StateMirror.write(Snapshot(playback: playback, updatedAt: Date()), to: stateFile)
    }

    // MARK: album-art palette

    private func updatePalette(for url: URL?) async {
        guard let url else {
            if !palette.isEmpty { palette = [] }
            return
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        let colors = Self.extractPalette(from: cg)
        if !colors.isEmpty { palette = colors }
    }

    /// Quantizes the artwork into 3-bit-per-channel buckets and returns the
    /// most prominent colors, weighted toward vibrant ones.
    private static func extractPalette(from cgImage: CGImage, maxColors: Int = 4) -> [Color] {
        let dim = 32
        var pixels = [UInt8](repeating: 0, count: dim * dim * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: dim, height: dim, bitsPerComponent: 8,
            bytesPerRow: dim * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dim, height: dim))

        struct Bucket { var count = 0; var r = 0; var g = 0; var b = 0 }
        var buckets: [Int: Bucket] = [:]
        var i = 0
        while i < pixels.count {
            let r = Int(pixels[i]); let g = Int(pixels[i + 1]); let b = Int(pixels[i + 2]); let a = Int(pixels[i + 3])
            i += 4
            if a < 100 { continue }
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            var bk = buckets[key] ?? Bucket()
            bk.count += 1; bk.r += r; bk.g += g; bk.b += b
            buckets[key] = bk
        }
        guard !buckets.isEmpty else { return [] }

        func saturation(_ r: Double, _ g: Double, _ b: Double) -> Double {
            let mx = max(r, g, b), mn = min(r, g, b)
            return mx <= 0 ? 0 : (mx - mn) / mx
        }

        let scored: [(Color, Double)] = buckets.values.map { bk in
            let r = Double(bk.r) / Double(bk.count)
            let g = Double(bk.g) / Double(bk.count)
            let b = Double(bk.b) / Double(bk.count)
            let sat = saturation(r / 255, g / 255, b / 255)
            let score = Double(bk.count) * (0.35 + sat)
            return (Color(red: r / 255, green: g / 255, blue: b / 255), score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(maxColors).map { $0.0 }
    }

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

        // playerInfo notifications only fire on track *changes*. If a player is
        // already playing when bob launches, seed the tile by asking the apps
        // directly via AppleScript.
        Task { await seedFromRunningPlayer() }
    }

    /// One-shot query of Music.app then Spotify at launch, so the tile reflects
    /// whatever's already playing. Skipped if a notification already populated
    /// `current`. Triggers a one-time Automation (TCC) prompt the first time.
    func seedFromRunningPlayer() async {
        guard current == nil else { return }

        if let (raw, source) = await Self.queryRunningPlayer() {
            let parts = raw.components(separatedBy: "\t")
            guard parts.count >= 4 else { return }
            let name = parts[0], artist = parts[1], album = parts[2]
            let state = parts[3].lowercased()
            guard current == nil, state != "stopped", !name.isEmpty else { return }

            let art = await lookupArtwork(artist: artist, album: album, track: name)
            let track = Track(name: name, artist: artist, album: album, durationMs: nil, artworkURL: art)
            adopt(Playback(source: source, state: state, track: track))
        }
    }

    /// Returns (tab-joined "name\tartist\talbum\tstate", source) for whichever
    /// of Music.app / Spotify is running and not stopped. Uses `is running` so
    /// it never launches the apps.
    private static func queryRunningPlayer() async -> (String, String)? {
        let music = """
        if application "Music" is running then
            tell application "Music"
                if player state is not stopped then
                    set t to current track
                    return (get name of t) & "\t" & (get artist of t) & "\t" & (get album of t) & "\t" & (player state as text)
                end if
            end tell
        end if
        return ""
        """
        if let out = await runOsascript(music), !out.isEmpty {
            return (out, "apple_music")
        }

        let spotify = """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is not stopped then
                    set t to current track
                    return (get name of t) & "\t" & (get artist of t) & "\t" & (get album of t) & "\t" & (player state as text)
                end if
            end tell
        end if
        return ""
        """
        if let out = await runOsascript(spotify), !out.isEmpty {
            return (out, "spotify")
        }
        return nil
    }

    private static func runOsascript(_ script: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: out)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
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
                self.adopt(Playback(source: "apple_music", state: "stopped", track: nil))
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
            self.adopt(Playback(source: "apple_music", state: state, track: track))
        }
    }

    @objc private func handleSpotify(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let stateRaw = (info["Player State"] as? String) ?? "Stopped"
        let state = stateRaw.lowercased()

        guard state != "stopped" else {
            Task { @MainActor in
                self.adopt(Playback(source: "spotify", state: "stopped", track: nil))
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
            self.adopt(Playback(source: "spotify", state: state, track: track))
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

}
