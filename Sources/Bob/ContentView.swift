import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = ClaudeBridge()
    @StateObject private var voiceIn = VoiceInput()
    @StateObject private var voiceOut = VoiceOutput()
    @ObservedObject private var home = BobHome.shared

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Tile(title: "work") { WorkTileContent() }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    Tile(title: "music") { MusicTileContent() }
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
                HStack(spacing: 14) {
                    Tile(title: "calendar") { CalendarTileContent() }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    Tile(title: "memory") { MemoryTileContent() }
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
                Tile(title: "talk") {
                    TalkTileContent(
                        bridge: bridge,
                        voiceIn: voiceIn,
                        voiceOut: voiceOut,
                        home: home
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .padding(16)
        }
        .task {
            await home.bootstrapIfNeeded()
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
