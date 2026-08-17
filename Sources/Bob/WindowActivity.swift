import AppKit
import Observation
import SwiftUI

/// Whether the hosting window is actually on glass — visible, un-occluded, not
/// hidden with the app. One instance per window, not a global: a floating
/// panel must not keep an occluded main window "awake", nor the reverse. Bound
/// by whoever owns the window, handed down the environment, and read by every
/// always-on render loop (comet, orb, waveform, pulse dots) so they pause the
/// moment nobody can see them. The unbound default never flips, which keeps
/// previews and one-off windows behaving like today.
@MainActor @Observable
final class WindowActivity {
    private(set) var isVisible = true

    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    nonisolated init() {}

    func bind(to window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
        let onMain: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                           object: window, queue: .main, using: onMain),
            // occlusion can lag an app-wide hide/unhide — re-check on both
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main, using: onMain),
            nc.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main, using: onMain),
        ]
        refresh()
    }

    private func refresh() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        if visible != isVisible { isVisible = visible }
    }
}

private struct WindowActivityKey: EnvironmentKey {
    static let defaultValue = WindowActivity()
}

extension EnvironmentValues {
    var windowActivity: WindowActivity {
        get { self[WindowActivityKey.self] }
        set { self[WindowActivityKey.self] = newValue }
    }
}
