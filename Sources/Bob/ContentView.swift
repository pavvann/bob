import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = ClaudeBridge()
    @StateObject private var voiceIn = VoiceInput()
    @StateObject private var voiceOut = VoiceOutput()
    @ObservedObject private var home = BobHome.shared

    @ObservedObject private var minions = MinionService.shared
    @ObservedObject private var music = MusicService.shared
    @State private var showMemory = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            // album-art vibe — washes the window with the current track's colors
            AmbientBackground(palette: music.palette, active: music.isPlaying)

            HStack(spacing: 14) {
                VStack(spacing: 18) {
                    // ambient context — glanceable strip across the top
                    HStack(spacing: 12) {
                        Tile(title: "work") { WorkTileContent() }
                        Tile(title: "music") { MusicTileContent() }
                        Tile(title: "calendar") { CalendarTileContent() }
                        Tile(title: "weather") { WeatherTileContent() }
                    }
                    .frame(height: 110)

                    Spacer(minLength: 0)

                    // bob — the conductor, centered
                    CenterStage(bridge: bridge, voiceIn: voiceIn, voiceOut: voiceOut, home: home)
                        .frame(maxWidth: 640)

                    // minions bob has delegated tasks to
                    if !minions.active.isEmpty {
                        MinionStrip(minions: minions.active)
                            .frame(maxWidth: 640)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                if showMemory {
                    Tile(title: "memory") { MemoryTileContent() }
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: minions.active)

            memoryToggle
        }
        .task {
            await home.bootstrapIfNeeded()
        }
    }

    private var memoryToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { showMemory.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(showMemory ? Color.accentColor.opacity(0.85) : .secondary.opacity(0.55))
                .padding(7)
                .background { Circle().fill(.ultraThinMaterial) }
        }
        .buttonStyle(.plain)
        .help(showMemory ? "hide memory" : "show memory")
        .padding(.top, 12)
        .padding(.trailing, 14)
    }
}

// MARK: minions

/// A row of the little agent cards bob has delegated tasks to.
private struct MinionStrip: View {
    let minions: [MinionService.Minion]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(minions) { minion in
                MinionCard(minion: minion)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MinionCard: View {
    let minion: MinionService.Minion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(minion.task)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                subtitle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if minion.status == "working", let start = minion.startedAt {
            // live elapsed timer while the minion grinds in the background
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("working · \(elapsed(from: start, to: ctx.date))")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineLimit(1)
            }
        } else if let detail = minion.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 9, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    @ViewBuilder
    private var statusDot: some View {
        switch minion.status {
        case "done":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.85))
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
        case "queued":
            Circle()
                .strokeBorder(.secondary.opacity(0.5), lineWidth: 1.4)
                .frame(width: 7, height: 7)
        default: // working
            Circle()
                .fill(Color.accentColor.opacity(0.9))
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.0 : 0.5)
                .opacity(pulse ? 1.0 : 0.4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
        }
    }
}

// MARK: tile contents

private struct PlaceholderTileContent: View {
    let primary: String
    let secondary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(primary)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.72))
            Text(secondary)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.45))
            Spacer(minLength: 0)
        }
    }
}

private struct WorkTileContent: View {
    @ObservedObject private var service = GitHubService.shared

    private enum Section: Hashable {
        case reviewRequests
        case openPRs
    }

    @State private var expanded: Section?

    var body: some View {
        if let state = service.state {
            if !state.ghAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    Text("github not connected")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.75))
                    if let err = state.lastError {
                        Text(err)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            } else if isAllClear(state) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("all clear")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("no PRs to review, no unread notifications.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.45))
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.reviewRequests.isEmpty {
                            expandableRow(
                                section: .reviewRequests,
                                icon: "eye",
                                tint: .blue,
                                count: state.reviewRequests.count,
                                singular: "PR awaiting your review",
                                plural: "PRs awaiting your review",
                                prs: state.reviewRequests
                            )
                        }
                        if !state.openPRs.isEmpty {
                            expandableRow(
                                section: .openPRs,
                                icon: "arrow.triangle.pull",
                                tint: .green,
                                count: state.openPRs.count,
                                singular: "PR of yours open",
                                plural: "PRs of yours open",
                                prs: state.openPRs
                            )
                        }
                        if state.unreadNotifications > 0 {
                            Button {
                                if let url = URL(string: "https://github.com/notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                rowLabel(
                                    icon: "bell",
                                    tint: .orange,
                                    count: state.unreadNotifications,
                                    text: state.unreadNotifications == 1 ? "unread notification" : "unread notifications",
                                    chevron: "arrow.up.right"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .scrollIndicators(.never)
            }
        } else {
            Text("loading...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    private func isAllClear(_ s: GitHubService.State) -> Bool {
        s.reviewRequests.isEmpty && s.openPRs.isEmpty && s.unreadNotifications == 0
    }

    private func expandableRow(
        section: Section,
        icon: String,
        tint: Color,
        count: Int,
        singular: String,
        plural: String,
        prs: [GitHubService.PR]
    ) -> some View {
        let isOpen = expanded == section
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    expanded = isOpen ? nil : section
                }
            } label: {
                rowLabel(
                    icon: icon,
                    tint: tint,
                    count: count,
                    text: count == 1 ? singular : plural,
                    chevron: isOpen ? "chevron.up" : "chevron.down"
                )
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(prs) { pr in
                        Button {
                            if let url = URL(string: pr.url) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                Text(pr.title)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary.opacity(0.88))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                Text(pr.repo)
                                    .font(.system(size: 9, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary.opacity(0.55))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            .padding(.vertical, 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 22)
                .padding(.top, 2)
            }
        }
    }

    private func rowLabel(icon: String, tint: Color, count: Int, text: String, chevron: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 14)
            (Text("\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.9))
             + Text(" \(text)")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
            )
                .lineLimit(1)
            Spacer()
            Image(systemName: chevron)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .contentShape(Rectangle())
    }
}

private struct WeatherTileContent: View {
    @ObservedObject private var service = WeatherService.shared

    var body: some View {
        switch service.locationStatus {
        case .notDetermined:
            connectView
        case .denied, .restricted:
            deniedView
        default:
            // .authorized / .authorizedAlways on macOS
            authorizedView
        }
    }

    private var connectView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                service.requestAccess()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 11))
                    Text("connect location")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.blue.opacity(0.9))
            }
            .buttonStyle(.plain)
            Text("local weather, updated through the day.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var deniedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("location access denied")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("enable in system settings →")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var authorizedView: some View {
        if let s = service.state {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: s.symbolName)
                    .font(.system(size: 30, weight: .light))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(s.temperatureC.rounded()))°")
                        .font(.system(size: 26, weight: .light, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                    Text(s.condition)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                    if let high = s.highC, let low = s.lowC {
                        Text("H:\(Int(high.rounded()))°  L:\(Int(low.rounded()))°")
                            .font(.system(size: 10, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    Text(s.locationName)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        } else if let err = service.lastError {
            VStack(alignment: .leading, spacing: 4) {
                Text(err)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        } else {
            Text("loading weather...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

private struct CalendarTileContent: View {
    @ObservedObject private var service = CalendarService.shared

    var body: some View {
        switch service.authorization {
        case .notDetermined, .unknown:
            unauthorizedConnectView
        case .denied, .restricted:
            deniedView
        case .fullAccess, .writeOnly:
            authorizedView
        }
    }

    private var unauthorizedConnectView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await service.requestAccess() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11))
                    Text("connect calendar")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.blue.opacity(0.9))
            }
            .buttonStyle(.plain)
            Text("show next event + join link for in-progress meetings.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var deniedView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("calendar access denied")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.7))
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("enable in system settings →")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.blue.opacity(0.85))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var authorizedView: some View {
        if let state = service.state {
            if let now = state.now {
                eventCard(event: now, isInProgress: true)
            } else if let next = state.next {
                eventCard(event: next, isInProgress: false)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("nothing scheduled")
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text("you're clear for the next 7 days.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Spacer(minLength: 0)
                }
            }
        } else {
            Text("loading...")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    private func eventCard(event: CalendarService.Event, isInProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isInProgress {
                    Circle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 7, height: 7)
                }
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(timingText(event: event, isInProgress: isInProgress))
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.75))
            if !event.calendarTitle.isEmpty {
                Text(event.calendarTitle)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            if let conference = event.conferenceURL, let url = URL(string: conference) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9))
                        Text("join")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.blue.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(.blue.opacity(0.12))
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func timingText(event: CalendarService.Event, isInProgress: Bool) -> String {
        if isInProgress {
            return "ends \(humanInterval(from: Date(), to: event.endDate))"
        } else {
            return "starts \(humanInterval(from: Date(), to: event.startDate)) · \(absoluteTime(event.startDate))"
        }
    }

    /// "in 12m" / "in 1h 5m" / "in 2d 3h" etc.
    private func humanInterval(from start: Date, to end: Date) -> String {
        let interval = max(0, end.timeIntervalSince(start))
        if interval < 60 { return "now" }
        if interval < 3600 {
            return "in \(Int(interval / 60))m"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            let mins = Int((interval - Double(hours) * 3600) / 60)
            return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
        }
        let days = Int(interval / 86400)
        let hours = Int((interval - Double(days) * 86400) / 3600)
        return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
    }

    private func absoluteTime(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            return f.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            let f = DateFormatter(); f.dateFormat = "'tomorrow,' h:mm a"
            return f.string(from: date)
        }
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return f.string(from: date)
    }
}

private struct MusicTileContent: View {
    @ObservedObject private var service = MusicService.shared

    var body: some View {
        if let playback = service.current, let track = playback.track {
            HStack(alignment: .top, spacing: 12) {
                artwork(url: track.artworkURL)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                    if playback.state != "playing" {
                        Text(playback.state)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.55))
                            .textCase(.uppercase)
                            .tracking(0.7)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("nothing playing")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
                Text("ask bob to play something.")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholderArt
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            placeholderArt
                .frame(width: 56, height: 56)
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.secondary.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.55))
            }
    }
}

private struct MemoryTileContent: View {
    @State private var entries: [String] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !loaded {
                EmptyView()
            } else if entries.isEmpty {
                Text("nothing here yet.")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.6))
            } else {
                ForEach(Array(entries.prefix(4).enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .task {
            entries = Self.loadEntries()
            loaded = true
        }
    }

    /// Parses bullets under the `## entries` heading of `~/bob/MEMORY.md`.
    private static func loadEntries() -> [String] {
        let path = BobHome.shared.root.appendingPathComponent("MEMORY.md")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var result: [String] = []
        var inEntries = false
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("##") {
                inEntries = line.localizedCaseInsensitiveContains("entries")
                continue
            }
            if inEntries {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    result.append(String(trimmed.dropFirst(2)))
                }
            }
        }
        return result.reversed()
    }
}
