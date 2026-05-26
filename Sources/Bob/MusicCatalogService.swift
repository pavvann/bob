import Foundation
import MusicKit

/// Plays Apple Music catalog tracks (not just library) via the MusicKit
/// framework. Wired up so the play-music skill can hand off a catalog ID via
/// `bob://music/play?id=<id>` and bob actually starts playback through
/// `SystemMusicPlayer.shared` — no AppleScript / UI scripting hacks.
@MainActor
final class MusicCatalogService: ObservableObject {
    static let shared = MusicCatalogService()

    @Published private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus

    private init() {}

    /// Play an Apple Music catalog track by its ID (the same ID iTunes Search
    /// API returns as `trackId`). Requests MusicKit authorization on first use.
    func play(catalogId: String) async {
        Self.log("play(catalogId=\(catalogId))")

        if authorization != .authorized {
            Self.log("requesting MusicKit authorization (current=\(authorization))")
            authorization = await MusicAuthorization.request()
            Self.log("authorization result: \(authorization)")
        }

        guard authorization == .authorized else {
            Self.log("aborting — not authorized")
            return
        }

        do {
            let itemID = MusicItemID(catalogId)
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: itemID)
            let response = try await request.response()

            guard let song = response.items.first else {
                Self.log("song with id \(catalogId) not found in catalog")
                return
            }

            Self.log("found: \"\(song.title)\" by \(song.artistName) — queuing + playing")
            // SystemMusicPlayer is iOS-only. On macOS the available class is
            // ApplicationMusicPlayer — plays through bob's audio session
            // (not Music.app). com.apple.Music.playerInfo doesn't fire for this
            // playback path, so we push the now-playing state directly to
            // MusicService below so the music tile updates.
            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
            try await player.play()
            Self.log("playback started via ApplicationMusicPlayer")

            let artworkURL = song.artwork?.url(width: 512, height: 512)
            let durationMs: Double? = song.duration.map { $0 * 1000 }
            let track = MusicService.Track(
                name: song.title,
                artist: song.artistName,
                album: song.albumTitle ?? "",
                durationMs: durationMs,
                artworkURL: artworkURL
            )
            MusicService.shared.publish(track: track, state: "playing", source: "apple_music_catalog")
            Self.log("pushed now-playing to MusicService tile")
        } catch {
            Self.log("MusicKit error: \(String(describing: error))")
        }
    }

    // MARK: debug log

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob/state/music-debug.log")
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
