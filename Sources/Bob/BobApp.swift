import SwiftUI
import AppKit
import ApplicationServices

@main
struct BobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window` (not `WindowGroup`) is a single-instance scene — URL events
        // and re-activations route to the existing window instead of spawning
        // a new one. Kills the "two bob windows" bug.
        Window("bob", id: "main") {
            ContentView()
                .frame(minWidth: 820, idealWidth: 1120, maxWidth: 1440,
                       minHeight: 540, idealHeight: 680, maxHeight: 1000)
                .background(WindowAccessor { window in
                    Self.style(window)
                })
                .onOpenURL { url in
                    BobURLHandler.handle(url, source: "onOpenURL")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 680)
    }

    static func style(_ window: NSWindow) {
        // the panel controller (and ⌥Space toggle) need to tell bob's main
        // window apart from floating session panels
        SessionPanelController.shared.adoptMainWindow(window)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        // Don't let the green button or system gestures send bob to fullscreen —
        // it should always feel like a floating panel, not an app that takes over a Space.
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.center()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // ⌥Space summons bob from anywhere — the Spotlight feel.
        // (Esc-to-dismiss is handled in CenterStage's input so it clears the
        // field first and only hides when empty — see .onKeyPress(.escape).)
        HotKeyManager.shared.onTrigger = { HotKeyManager.toggleBob() }
        HotKeyManager.shared.register()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Backup URL handler. SwiftUI's `.onOpenURL` should fire first; this
    /// catches URLs if SwiftUI doesn't deliver them for some reason.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            BobURLHandler.handle(url, source: "AppDelegate")
        }
    }
}

/// Handles `bob://` URL scheme commands. Routed from SwiftUI's `.onOpenURL` —
/// bob's Accessibility grant covers AX inspection of other apps, so this is
/// how claude triggers Music.app actions without going through osascript.
enum BobURLHandler {
    static func handle(_ url: URL, source: String = "?") {
        log("url received via \(source): \(url.absoluteString)")
        guard url.scheme == "bob" else {
            log("ignoring non-bob:// scheme")
            return
        }
        switch url.host {
        case "play-key":
            pressPlayInMusic()
        case "music":
            handleMusicCommand(url)
        default:
            log("unknown bob:// host: \(url.host ?? "<nil>")")
        }
    }

    /// `bob://music/play?id=<catalog-id>` — play an Apple Music catalog track
    /// via MusicKit (SystemMusicPlayer). The skill curls iTunes Search to get
    /// the trackId, then opens this URL so bob's Swift code does the play.
    private static func handleMusicCommand(_ url: URL) {
        let action = url.pathComponents.dropFirst().first ?? ""
        switch action {
        case "play":
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "id" })?.value, !id.isEmpty else {
                log("bob://music/play missing id query parameter")
                return
            }
            log("bob://music/play id=\(id)")
            Task { @MainActor in
                await MusicCatalogService.shared.play(catalogId: id)
            }
        default:
            log("unknown bob://music action: '\(action)'")
        }
    }

    private static func pressPlayInMusic() {
        log("--- play-key URL received ---")
        let trusted = AXIsProcessTrusted()
        log("AXIsProcessTrusted: \(trusted)")
        if !trusted {
            log("→ bob does NOT have Accessibility. System Settings → Privacy & Security → Accessibility, remove old bob entries, add this Bob.app, toggle on.")
            let opts: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
            _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
            return
        }

        guard let music = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.Music"
        }) else {
            log("Music.app not running; aborting")
            return
        }
        music.activate()
        let pid = music.processIdentifier
        log("activated Music (pid \(pid))")

        // Wait for the track page to render fully.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            let app = AXUIElementCreateApplication(pid)

            // Attempt 1: simple AXButton titled "Play". Works for album / playlist
            // header pages where there's a prominent Play button.
            if let button = findFirstPlayButton(in: app) {
                let title = axString(button, kAXTitleAttribute) ?? "<no title>"
                log("path A — AXButton 'Play': title='\(title)' — pressing")
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                log("press result: \(axResultName(result))")
                return
            }

            // Attempt 2: catalog ?i= track page. The play control is `checkbox 1`
            // of an AXGroup containing an AXButton with description "Favorite".
            // The checkbox only materialises after a real mouse hover, so we
            // post a CGEvent mouseMoved to the row centre, wait, then click.
            // Source: epheterson/applemusic-mcp _find_highlighted_track_position
            // + _play_specific_track.
            if let (group, centre) = findHighlightedTrackGroup(in: app) {
                log("path B — highlighted row centre=\(centre); hovering then clicking checkbox")
                hoverWithNudge(target: centre)

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if let checkbox = findFirstCheckbox(in: group) {
                        log("clicking checkbox 1 of highlighted row")
                        let result = AXUIElementPerformAction(checkbox, kAXPressAction as CFString)
                        log("checkbox click result: \(axResultName(result))")
                    } else {
                        log("checkbox did not materialise after hover — row may have collapsed or scrolled away")
                    }
                }
            } else {
                log("no Play button and no highlighted track row found — dumping AX")
                dumpAllButtons(in: app)
            }
        }
    }

    /// Finds the AXGroup representing the currently-highlighted track row on a
    /// catalog `?i=` page. The row is identified by having a child AXButton
    /// whose `description` is "Favorite". Returns the group + its centre point
    /// in screen coordinates.
    private static func findHighlightedTrackGroup(in root: AXUIElement) -> (AXUIElement, CGPoint)? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxVisits = 6000

        while !queue.isEmpty, visited < maxVisits {
            let element = queue.removeFirst()
            visited += 1

            let role = axString(element, kAXRoleAttribute) ?? ""
            if role == kAXGroupRole {
                if let children = axChildren(element) {
                    for child in children {
                        let childRole = axString(child, kAXRoleAttribute) ?? ""
                        guard childRole == kAXButtonRole else { continue }
                        let desc = axString(child, kAXDescriptionAttribute) ?? ""
                        if desc == "Favorite" {
                            if let bounds = axBounds(of: element) {
                                let centre = CGPoint(
                                    x: bounds.origin.x + bounds.size.width / 2,
                                    y: bounds.origin.y + bounds.size.height / 2
                                )
                                return (element, centre)
                            }
                        }
                    }
                }
            }

            if let children = axChildren(element) {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    private static func findFirstCheckbox(in element: AXUIElement) -> AXUIElement? {
        guard let children = axChildren(element) else { return nil }
        for child in children {
            let role = axString(child, kAXRoleAttribute) ?? ""
            if role == kAXCheckBoxRole {
                return child
            }
        }
        return nil
    }

    /// Hover the cursor at `target` via two CGEvents — a nudge away then to the
    /// target. The nudge ensures macOS posts a real hover state change even if
    /// the cursor was already near the target. See `_hover_with_nudge` in
    /// applemusic-mcp; needed for reliable behaviour on Sequoia.
    private static func hoverWithNudge(target: CGPoint) {
        let away = CGPoint(x: target.x - 40, y: target.y - 40)
        postMouseMove(to: away)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postMouseMove(to: target)
        }
    }

    private static func postMouseMove(to point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil,
                            mouseType: .mouseMoved,
                            mouseCursorPosition: point,
                            mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    private static func axBounds(of element: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        var sizeValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard let pv = posValue, let sv = sizeValue else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        if !AXValueGetValue(pv as! AXValue, .cgPoint, &pos) { return nil }
        if !AXValueGetValue(sv as! AXValue, .cgSize, &size) { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func axResultName(_ result: AXError) -> String {
        switch result {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .actionUnsupported: return "actionUnsupported"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .apiDisabled: return "apiDisabled (no Accessibility)"
        default: return "raw \(result.rawValue)"
        }
    }

    /// Walks Music.app's accessibility tree breadth-first looking for the most
    /// likely "Play" button on the current view.
    private static func findFirstPlayButton(in root: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxVisits = 4000

        while !queue.isEmpty, visited < maxVisits {
            let element = queue.removeFirst()
            visited += 1

            let role = axString(element, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole {
                let title = (axString(element, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespaces)
                let desc = (axString(element, kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespaces)
                let label = (title.isEmpty ? desc : title).lowercased()
                if (label == "play" || label.hasPrefix("play ")) && !label.contains("preview") && !label.contains("pause") {
                    return element
                }
            }

            if let children = axChildren(element) {
                queue.append(contentsOf: children)
            }
        }
        return nil
    }

    /// Diagnostic: dump every button's role/title/desc/identifier to the log.
    private static func dumpAllButtons(in root: AXUIElement) {
        log("--- AX button dump ---")
        var queue: [AXUIElement] = [root]
        var visited = 0
        let maxVisits = 4000
        while !queue.isEmpty, visited < maxVisits {
            let element = queue.removeFirst()
            visited += 1
            let role = axString(element, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole || role == "AXMenuButton" || role == "AXPopUpButton" {
                let title = axString(element, kAXTitleAttribute) ?? ""
                let desc = axString(element, kAXDescriptionAttribute) ?? ""
                let ident = axString(element, kAXIdentifierAttribute) ?? ""
                log("  [\(role)] title='\(title)' desc='\(desc)' id='\(ident)'")
            }
            if let children = axChildren(element) {
                queue.append(contentsOf: children)
            }
        }
        log("--- end dump (visited \(visited)) ---")
    }

    // MARK: AX helpers

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return value as? String
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement]
    }

    // MARK: debug log

    private static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("bob/state/play-debug.log")
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

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
