import Foundation
import AppKit
import SwiftUI

/// A transparent menu-bar panel avoids stacking the popover's opaque material
/// under the native clear-glass surface supplied by ContentView.
final class GlassMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        if NSApp.modalWindow === self { NSApp.stopModal(withCode: .cancel) }
        else { orderOut(nil) }
    }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    public static weak var shared: AppDelegate?
    public private(set) var libraryWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var panel: GlassMenuPanel!
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        HTTPServer.shared.start(port: ClipStore.shared.port)
        UDPDiscoveryServer.shared.start(port: 5679)
        ShortcutManager.shared.register()
        panel = GlassMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = TransparentHostingView(rootView: ContentView())
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "ClipToMac")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard NSApp.modalWindow == nil else { return }
            self?.panel.orderOut(nil)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible, NSApp.modalWindow == nil else { return event }
            if event.window !== self.panel && event.window !== self.statusItem.button?.window &&
                event.window?.parent !== self.panel && event.window?.sheetParent !== self.panel {
                self.panel.orderOut(nil)
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onNewClip), name: NSNotification.Name("NewClipReceived"), object: nil)
    }

    @objc public func openLibrary() {
        panel?.orderOut(nil)
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ClipToMac Library"
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.contentView = TransparentHostingView(rootView: LibraryView())
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func togglePopover() {
        guard let button = statusItem.button, let anchorWindow = button.window else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        ClipStore.shared.updateLocalIP()
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = max(visible.minY + 8, anchor.minY - panel.frame.height - 7)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Notification.Name("ClipToMacMenuOpened"), object: nil)
    }

    @objc func onNewClip() {
        guard let button = statusItem.button else { return }
        let original = button.image
        let image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: "New clip")
        image?.isTemplate = true
        button.image = image
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { button.image = original }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        HTTPServer.shared.stop()
        UDPDiscoveryServer.shared.stop()
    }
}
