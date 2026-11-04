import Foundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    public static weak var shared: AppDelegate?
    public private(set) var libraryWindow: NSWindow?
    private var phoneNotificationDetailWindow: NSWindow?
    private let libraryNavigation = LibraryNavigation()
    private var statusItem: NSStatusItem!
    private var panel: GlassMenuPanel!
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        UNUserNotificationCenter.current().delegate = self
        PhoneNotificationRelay.shared.registerNotificationActions()
        BucketTransferStorage.shared.pruneCommitted({ ClipStore.shared.seenTransferAttempt($0) }, isCancelled: { IncomingTransferControls.shared.isCancelled(scopedID: $0) })
        MacTransferService.shared.restoreIncomingTransfers()
        HTTPServer.shared.start(port: ClipStore.shared.port)
        UDPDiscoveryServer.shared.start(port: 5679)
        ShortcutManager.shared.register()
        panel = GlassMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.02)
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = TransparentHostingView(rootView: ContentView().appTypography())
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "ClipToMac")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem.autosaveName = "com.vdx.cliptomac.menu-bar"
        statusItem.isVisible = true
        NSLog("ClipToMac: menu bar item registered and visible")
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
        openLibrary()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openLibrary() }
        return true
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
            window.titlebarAppearsTransparent = false
            window.contentView = TransparentHostingView(rootView: LibraryView(navigation: libraryNavigation).appTypography())
            window.center()
            libraryWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    func openPhoneNotificationHistory() {
        libraryNavigation.showsPhoneNotifications = true
        openLibrary()
    }

    public func showPhoneNotificationDetail(
        appName: String, title: String, body: String, sendReply: ((String) -> Bool)? = nil
    ) {
        panel?.orderOut(nil)
        let content = TransparentHostingView(rootView: PhoneNotificationDetailView(appName: appName, title: title, bodyText: body, sendReply: sendReply).appTypography())
        if let window = phoneNotificationDetailWindow {
            window.contentView = content
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Notification"
            window.minSize = NSSize(width: 420, height: 250)
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = content
            window.center()
            phoneNotificationDetailWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        phoneNotificationDetailWindow?.makeKeyAndOrderFront(nil)
    }

    public func closePhoneNotificationDetail() {
        phoneNotificationDetailWindow?.performClose(nil)
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
        NSApp.activate(ignoringOtherApps: true)
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let category = notification.request.content.categoryIdentifier
        completionHandler(PhoneNotificationRelay.foregroundPresentation(for: category))
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(); return }
            self.handlePhoneNotificationResponse(response)
            completionHandler()
        }
    }

    @MainActor private func handlePhoneNotificationResponse(_ response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        let eventID = info["eventID"] as? String ?? ""
        let deviceID = info["deviceID"] as? String ?? ""
        switch response.actionIdentifier {
        case PhoneNotificationRelay.markReadActionID:
            if !PhoneNotificationRelay.shared.enqueueMarkRead(deviceID: deviceID, eventID: eventID) {
                NSLog("ClipToMac: Android mark as read could not be queued")
            }
        case PhoneNotificationRelay.muteActionID:
            guard let packageName = info["packageName"] as? String else { return }
            PhoneNotificationRelay.shared.muteSource(deviceID: deviceID, packageName: packageName)
        case PhoneNotificationRelay.viewActionID:
            showPhoneNotificationDetail(
                appName: info["appName"] as? String ?? "Android notification",
                title: info["sourceTitle"] as? String ?? "",
                body: info["fullBody"] as? String ?? response.notification.request.content.body
            )
        case PhoneNotificationRelay.replyActionID:
            guard let reply = response as? UNTextInputNotificationResponse else { return }
            let queued = PhoneNotificationRelay.shared.enqueueReply(deviceID: deviceID, eventID: eventID, text: reply.userText)
            if !queued { NSLog("ClipToMac: Android notification reply could not be queued") }
        case UNNotificationDefaultActionIdentifier:
            guard !eventID.isEmpty, !deviceID.isEmpty else { return }

            let sendReply: ((String) -> Bool)?
            if info["canReply"] as? Bool == true {
                sendReply = { text in
                    PhoneNotificationRelay.shared.enqueueReply(deviceID: deviceID, eventID: eventID, text: text)
                }
            } else {
                sendReply = nil
            }
            showPhoneNotificationDetail(
                appName: info["appName"] as? String ?? "Android notification",
                title: info["sourceTitle"] as? String ?? "",
                body: info["fullBody"] as? String ?? response.notification.request.content.body,
                sendReply: sendReply
            )
        default:
            break
        }
    }
}
