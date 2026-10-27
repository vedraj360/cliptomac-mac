import AppKit
import Carbon

extension Notification.Name { static let clipShortcutChanged = Notification.Name("ClipShortcutChanged") }

@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.toggleLibrary() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        NotificationCenter.default.addObserver(self, selector: #selector(register), name: .clipShortcutChanged, object: nil)
        register()
    }
    @objc func register() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let store = ClipStore.shared
        let id = EventHotKeyID(signature: OSType(0x43544D43), id: 1)
        RegisterEventHotKey(store.shortcutKeyCode, store.shortcutModifiers, id, GetApplicationEventTarget(), 0, &hotKey)
    }
    private func toggleLibrary() {
        if let window = AppDelegate.shared?.libraryWindow, window.isVisible { window.orderOut(nil) }
        else { AppDelegate.shared?.openLibrary() }
    }
}
