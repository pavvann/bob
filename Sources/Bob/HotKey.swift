import AppKit
import Carbon.HIToolbox

/// System-wide hotkey to summon bob from anywhere — the Spotlight feel.
/// ⌥Space toggles bob: press it in any app and bob slides to the front, focused
/// and ready; press it again (with bob frontmost) and bob steps aside, returning
/// you to where you were. Uses Carbon's RegisterEventHotKey — no Accessibility
/// permission needed, consumes the event system-wide.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onTrigger: (() -> Void)?

    /// Posted when bob is summoned, so the input field can refocus (onAppear
    /// won't fire when an already-created window is re-shown).
    static let didSummon = Notification.Name("bob.didSummon")

    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onTrigger?() }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        // 'BOBX' signature so this hotkey id is unambiguous.
        let hotKeyID = EventHotKeyID(signature: OSType(0x424F4258), id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    /// Toggle bob's presence the way a launcher would: summon-and-focus if it's
    /// not the active foreground window, step aside otherwise.
    static func toggleBob() {
        let app = NSApp!
        let bobIsFront = app.isActive && (app.windows.first(where: { $0.isVisible })?.isKeyWindow ?? false)

        if bobIsFront {
            app.hide(nil)
        } else {
            app.activate(ignoringOtherApps: true)
            if let window = app.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.center()
            }
            NotificationCenter.default.post(name: HotKeyManager.didSummon, object: nil)
        }
    }
}
