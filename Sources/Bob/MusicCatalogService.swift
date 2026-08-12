import Foundation
import Combine
import MusicKit

/// Plays Apple Music catalog tracks (not just library) via the MusicKit
/// framework, in-process through `ApplicationMusicPlayer`.
///
/// Why not Music.app: `SystemMusicPlayer` and MediaPlayer's
/// `MPMusicPlayerController` are both `@available(macOS, unavailable)`
/// (verified against the macOS 26.5 SDK swiftinterface), so catalog playback
/// can't be routed through Music.app without AX hacks. bob owns the audio
/// session instead, and compensates for the downsides:
/// - `bob://music/play?ids=a,b,c` queues multiple tracks in order
/// - when the queue drains, playback continues with the last song's station
///   (song radio), so music doesn't just stop after the queue
/// - `bob://music/pause|resume|next|prev|stop` gives transport control,
///   since AppleScript can't see this player
/// - every track/state change is pushed to MusicService so the tile and
///   `~/bob/state/music.json` stay fresh (Music.app's playerInfo
///   notification never fires for this playback path)
@MainActor
final class MusicCatalogService: ObservableObject {
    static let shared = MusicCatalogService()

    @Published private(set) var authorization: MusicAuthorization.Status = MusicAuthorization.currentStatus

    /// Song radio for the last explicitly-queued track — started when the
    /// queue drains. Cleared by an explicit `stop` so that actually stops.
    private var drainStation: Station?
    private var stationStarted = false
    private var observers: [AnyCancellable] = []
    private var lastPublishedEntryID: MusicPlayer.Queue.Entry.ID?

    private init() {}

    /// Play one or more Apple Music catalog tracks by ID (the same IDs the
    /// iTunes Search API returns as `trackId`, IN storefront). Requests
    /// MusicKit authorization on first use. Order of `catalogIds` is the
    /// queue order.
    func play(catalogIds: [String]) async {
        Self.log("play(catalogIds=\(catalogIds.joined(separator: ",")))")

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
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id, memberOf: catalogIds.map { MusicItemID($0) })
            request.properties = [.station]
            let response = try await request.response()

            // response order isn't guaranteed — restore the requested order
            let byId = Dictionary(response.items.map { ($0.id.rawValue, $0) },
                                  uniquingKeysWith: { first, _ in first })
            let songs = catalogIds.compactMap { byId[$0] }

            guard !songs.isEmpty else {
                Self.log("no songs with ids \(catalogIds) found in catalog")
                return
            }
            if songs.count < catalogIds.count {
                Self.log("\(catalogIds.count - songs.count) of \(catalogIds.count) ids not found — playing the rest")
            }

            Self.log("queuing \(songs.count) song(s): " +
                     songs.map { "\"\($0.title)\" by \($0.artistName)" }.joined(separator: ", "))
            drainStation = songs.last?.station
            stationStarted = false

            let player = ApplicationMusicPlayer.shared
            player.queue = ApplicationMusicPlayer.Queue(for: songs)
            try await player.play()
            Self.log("playback started via ApplicationMusicPlayer — drain station: \(drainStation?.name ?? "none")")

            installObservers()
            publish(song: songs.first, state: "playing")
        } catch {
            Self.log("MusicKit error: \(String(describing: error))")
        }
    }

    // MARK: transport — bob://music/pause|resume|next|prev|stop

    func pause() {
        ApplicationMusicPlayer.shared.pause()
        Self.log("transport: pause")
    }

    func resume() async {
        do {
            try await ApplicationMusicPlayer.shared.play()
            Self.log("transport: resume")
        } catch {
            Self.log("transport resume failed: \(String(describing: error))")
        }
    }

    func skipToNext() async {
        do {
            try await ApplicationMusicPlayer.shared.skipToNextEntry()
            Self.log("transport: next")
        } catch {
            Self.log("transport next failed: \(String(describing: error))")
        }
    }

    func skipToPrevious() async {
        do {
            try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
            Self.log("transport: previous")
        } catch {
            Self.log("transport previous failed: \(String(describing: error))")
        }
    }

    func stop() {
        drainStation = nil
        ApplicationMusicPlayer.shared.stop()
        Self.log("transport: stop")
        MusicService.shared.publishCatalogState("stopped")
    }

    // MARK: player observation

    /// `objectWillChange` fires before values update; hopping through the
    /// main queue reads them after the change lands.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let player = ApplicationMusicPlayer.shared

        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.queueDidChange() }
            .store(in: &observers)

        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.stateDidChange() }
            .store(in: &observers)
    }

    private func queueDidChange() {
        guard let entry = ApplicationMusicPlayer.shared.queue.currentEntry else { return }
        guard entry.id != lastPublishedEntryID else { return }
        lastPublishedEntryID = entry.id
        Self.log("now playing: \"\(entry.title)\"\(entry.subtitle.map { " by \($0)" } ?? "")")
        publish(entry: entry, state: stateString())
    }

    private func stateDidChange() {
        let state = stateString()
        MusicService.shared.publishCatalogState(state)
        if state == "stopped" {
            maybeStartDrainStation()
        }
    }

    private func stateString() -> String {
        switch ApplicationMusicPlayer.shared.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: return "playing"
        case .paused, .interrupted: return "paused"
        case .stopped: return "stopped"
        @unknown default: return "stopped"
        }
    }

    /// The queue ran out (playback stopped without an explicit `stop`) —
    /// keep the music going with song radio for the last queued track.
    private func maybeStartDrainStation() {
        guard let station = drainStation, !stationStarted else { return }
        stationStarted = true
        Self.log("queue drained — continuing with station \"\(station.name)\"")
        Task { @MainActor in
            do {
                let player = ApplicationMusicPlayer.shared
                player.queue = ApplicationMusicPlayer.Queue(for: [station])
                try await player.play()
                Self.log("station playback started")
            } catch {
                Self.log("station playback failed: \(String(describing: error))")
            }
        }
    }

    // MARK: tile / music.json publishing

    private func publish(song: Song?, state: String) {
        guard let song else { return }
        let track = MusicService.Track(
            name: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            durationMs: song.duration.map { $0 * 1000 },
            artworkURL: song.artwork?.url(width: 512, height: 512)
        )
        MusicService.shared.publish(track: track, state: state, source: "apple_music_catalog")
    }

    private func publish(entry: MusicPlayer.Queue.Entry, state: String) {
        if case .song(let song) = entry.item {
            publish(song: song, state: state)
            return
        }
        // station entries can be transient for a beat — fall back to the
        // entry's own display fields
        let track = MusicService.Track(
            name: entry.title,
            artist: entry.subtitle ?? "",
            album: "",
            durationMs: nil,
            artworkURL: entry.artwork?.url(width: 512, height: 512)
        )
        MusicService.shared.publish(track: track, state: state, source: "apple_music_catalog")
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
