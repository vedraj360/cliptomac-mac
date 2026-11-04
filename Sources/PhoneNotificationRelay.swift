import AppKit
import Foundation
import CryptoKit
import UserNotifications
import SwiftUI

struct PhoneNotificationPayload: Decodable {
    let eventId: String
    let appName: String
    let packageName: String
    let title: String
    let body: String
    let timestamp: Int64
    let canReply: Bool?
    let canMarkRead: Bool?
    let showFullText: Bool?

    var isValid: Bool {
        eventId.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
            && !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appName.utf8.count <= 100
            && packageName.range(of: "^[A-Za-z0-9_.]{1,255}$", options: .regularExpression) != nil
            && title.utf8.count <= 180
            && body.utf8.count <= 8_000
            && (!title.isEmpty || !body.isEmpty)
            && timestamp <= Int64(Date().timeIntervalSince1970 * 1000) + 60_000
            && timestamp >= Int64(Date().timeIntervalSince1970 * 1000) - 5 * 60_000
    }
}

struct PhoneNotificationReplyCommand: Encodable {
    let id: String
    let eventId: String
    let text: String
    let markAsRead: Bool
}

@MainActor
final class PhoneNotificationRelay: ObservableObject {
    static let shared = PhoneNotificationRelay()

    private static let historyLimit = 50
    private static let bannerTimeout: UInt64 = 5_000_000_000
    private static let historyQueue = DispatchQueue(label: "com.vdx.cliptomac.notification-history")

    struct HistoryEntry: Identifiable, Codable {
        let id: String
        let appName: String
        let packageName: String?
        let title: String
        let body: String
        let receivedAt: Date
    }

    @Published private(set) var history: [HistoryEntry] = []

    private static var historyFile: URL? {
        #if CLIPTOMAC_TRANSFER_TEST
        return nil
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ClipToMac/NotificationHistory/notifications.json")
        #endif
    }

    private static var historyStorage: SQLiteAppState? {
        guard let legacy = historyFile else { return nil }
        return SQLiteAppState(directory: legacy.deletingLastPathComponent().deletingLastPathComponent(),
                              key: "notification-history")
    }

    private init() {
        guard let file = Self.historyFile, let storage = Self.historyStorage else { return }
        do {
            try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let entries = try storage.loadJSON([HistoryEntry].self, from: file) ?? []
            history = Array(entries.prefix(Self.historyLimit))
        } catch {
            historyLoadFailed = true
            NSLog("ClipToMac: notification history could not be loaded")
        }
    }

    private var historyLoadFailed = false

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    private func persistHistory() {
        guard !historyLoadFailed, let storage = Self.historyStorage else { return }
        let snapshot = history
        Self.historyQueue.async {
            do { try storage.save(snapshot) }
            catch { NSLog("ClipToMac: notification history could not be saved") }
        }
    }

    private struct PendingBanner {
        let payload: PhoneNotificationPayload
        let deviceID: String
    }

    private static let pendingBannerLimit = 10
    private static let bannerScreenInset: CGFloat = 12
    private static let bannerSlideDistance: CGFloat = 48
    private var bannerIsDismissing = false
    private var pendingBanners: [PendingBanner] = []
    private var banner: PhoneNotificationBannerPanel?
    private var bannerDismissal: Task<Void, Never>?

    enum Result { case delivered, ignored, rateLimited }

    private struct SeenEvent {
        let digest: String
        let date: Date
    }

    private var mutedSources: [String: Date] = [:]
    private var seen: [String: SeenEvent] = [:]
    private var recentEvents: [String: [Date]] = [:]
    private var markReadableEvents: [String: Date] = [:]
    private var replyableEvents: [String: Date] = [:]
    private var replyQueues: [String: [PhoneNotificationReplyCommand]] = [:]
    private var replyWaiters: [UUID: (deviceID: String, continuation: CheckedContinuation<PhoneNotificationReplyCommand?, Never>)] = [:]

    nonisolated static func foregroundPresentation(for category: String) -> UNNotificationPresentationOptions {
        guard category.hasPrefix("com.vdx.cliptomac.phoneNotification.") else { return [] }
        return [.banner, .list, .sound]
    }

    func registerNotificationActions() {
        let center = UNUserNotificationCenter.current()
        let reply = UNTextInputNotificationAction(identifier: Self.replyActionID, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let view = UNNotificationAction(identifier: Self.viewActionID, title: "View full message", options: [])
        let mute = UNNotificationAction(identifier: Self.muteActionID, title: "Mute app for 1 hour", options: [])
        let markRead = UNNotificationAction(identifier: Self.markReadActionID, title: "Mark as read", options: [])
        var categories: Set<UNNotificationCategory> = []
        for flags in 0..<8 {
            let hasReply = flags & 1 != 0
            let hasMarkRead = flags & 2 != 0
            let hasView = flags & 4 != 0
            var actions: [UNNotificationAction] = []
            if hasReply { actions.append(reply) }
            if hasMarkRead { actions.append(markRead) }
            actions.append(mute)
            if hasView { actions.append(view) }
            categories.insert(UNNotificationCategory(
                identifier: category(reply: hasReply, markRead: hasMarkRead, view: hasView),
                actions: actions, intentIdentifiers: [], options: []
            ))
        }
        center.setNotificationCategories(categories)
    }

    func receive(_ payload: PhoneNotificationPayload, from device: PairedDevice) -> Result {
        guard payload.isValid else { return .ignored }
        guard ClipStore.shared.phoneNotificationRelayEnabled else { return .ignored }

        let now = Date()
        mutedSources = mutedSources.filter { $0.value > now }
        guard mutedSources[replyKey(deviceID: device.id, eventID: payload.packageName)] == nil else {
            return .ignored
        }
        let scopedID = String(SHA256.hash(data: Data(device.id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) + "-" + payload.eventId
        let content = "\(payload.appName)\u{0}\(payload.title)\u{0}\(payload.body)\u{0}\(payload.canReply == true)\u{0}\(payload.canMarkRead == true)\u{0}\(payload.showFullText == true)"
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        if let previous = seen[scopedID], previous.digest == digest { return .ignored }

        let recent = (recentEvents[device.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 40 else { recentEvents[device.id] = recent; return .rateLimited }
        recentEvents[device.id] = recent + [now]
        replyableEvents = replyableEvents.filter { $0.value > now }
        markReadableEvents = markReadableEvents.filter { $0.value > now }
        let actionKey = replyKey(deviceID: device.id, eventID: payload.eventId)
        let expires = now.addingTimeInterval(15 * 60)
        replyableEvents[actionKey] = payload.canReply == true ? expires : nil
        markReadableEvents[actionKey] = payload.canMarkRead == true ? expires : nil

        seen[scopedID] = SeenEvent(digest: digest, date: now)
        if seen.count > 512 {
            let expired = seen.filter { now.timeIntervalSince($0.value.date) > 3600 }.map(\.key)
            expired.forEach { seen.removeValue(forKey: $0) }
            if seen.count > 512, let oldest = seen.min(by: { $0.value.date < $1.value.date })?.key { seen.removeValue(forKey: oldest) }
        }

        history.removeAll { $0.id == scopedID }
        history.insert(HistoryEntry(id: scopedID, appName: payload.appName, packageName: payload.packageName,
                                    title: payload.title,
                                    body: payload.body, receivedAt: now), at: 0)
        if history.count > Self.historyLimit { history.removeLast() }
        persistHistory()

        if ClipStore.shared.showSourceAppBanners,
           queueBanner(payload, deviceID: device.id) {
            return .delivered
        }

        let notification = UNMutableNotificationContent()
        notification.title = payload.title.isEmpty ? payload.appName : "\(payload.appName) · \(payload.title)"
        notification.body = payload.body
        notification.threadIdentifier = payload.packageName
        notification.sound = .default
        let wantsReply = payload.canReply == true
        let wantsFullText = payload.showFullText == true
        notification.categoryIdentifier = category(reply: wantsReply, markRead: payload.canMarkRead == true, view: wantsFullText)
        notification.userInfo = [
            "deviceID": device.id,
            "eventID": payload.eventId,
            "appName": payload.appName,
            "packageName": payload.packageName,
            "sourceTitle": payload.title,
            "fullBody": payload.body,
            "canReply": wantsReply,
            "showFullText": wantsFullText
        ]
        // Focus allowlists are controlled by macOS and cannot be inspected by the app.
        notification.interruptionLevel = .active
        let icon = makeIconAttachment(packageName: payload.packageName)
        if let icon { notification.attachments = [icon.attachment] }
        let request = UNNotificationRequest(identifier: scopedID, content: notification, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [scopedID])
        center.removeDeliveredNotifications(withIdentifiers: [scopedID])
        let iconFile = icon?.file
        center.add(request) { _ in
            if let iconFile { try? FileManager.default.removeItem(at: iconFile) }
        }
        return .delivered
    }

    func muteSource(deviceID: String, packageName: String) {
        guard !deviceID.isEmpty, !packageName.isEmpty else { return }
        mutedSources[replyKey(deviceID: deviceID, eventID: packageName)] = Date().addingTimeInterval(3600)
    }

    func sourceIcon(packageName: String) -> NSImage? {
        switch packageName {
        case "com.google.android.apps.messaging", "com.android.mms", "com.samsung.android.messaging":
            return NSImage(systemSymbolName: "message.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemBlue]))
        default:
            break
        }

        let bundledIcons = [
            "com.whatsapp": "whatsapp", "com.whatsapp.w4b": "whatsapp",
            "org.telegram.messenger": "telegram", "com.instagram.android": "instagram",
            "com.reddit.frontpage": "reddit", "com.twitter.android": "x",
            "com.google.android.youtube": "youtube", "com.android.chrome": "googlechrome",
            "com.brave.browser": "brave",
            "com.google.android.gm": "gmail",
            "com.facebook.katana": "facebook", "com.facebook.lite": "facebook",
            "com.facebook.orca": "messenger", "com.instagram.lite": "instagram"
        ]
        guard let name = bundledIcons[packageName],
              let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "BrandIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    private func makeIconAttachment(packageName: String) -> (attachment: UNNotificationAttachment, file: URL)? {
        guard let tiff = sourceIcon(packageName: packageName)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try png.write(to: file, options: .atomic)
            let attachment = try UNNotificationAttachment(identifier: "sourceAppIcon", url: file)
            return (attachment, file)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    private func queueBanner(_ payload: PhoneNotificationPayload, deviceID: String) -> Bool {
        guard NSScreen.main != nil else { return false }
        if banner == nil && !bannerIsDismissing { return showBanner(payload, deviceID: deviceID) }
        let entry = PendingBanner(payload: payload, deviceID: deviceID)
        if let index = pendingBanners.firstIndex(where: {
            $0.deviceID == deviceID && $0.payload.eventId == payload.eventId
        }) {
            pendingBanners[index] = entry
        } else {
            if pendingBanners.count >= Self.pendingBannerLimit { pendingBanners.removeFirst() }
            pendingBanners.append(entry)
        }
        return true
    }

    private func showNextBanner() {
        guard banner == nil else { return }
        while !pendingBanners.isEmpty {
            let next = pendingBanners.removeFirst()
            guard ClipStore.shared.phoneNotificationRelayEnabled else {
                pendingBanners.removeAll()
                return
            }
            if let mutedUntil = mutedSources[replyKey(deviceID: next.deviceID, eventID: next.payload.packageName)],
               mutedUntil > Date() { continue }
            if showBanner(next.payload, deviceID: next.deviceID) { return }
        }
    }

    private func showBanner(_ payload: PhoneNotificationPayload, deviceID: String) -> Bool {
        guard let screen = NSScreen.main, banner?.isKeyWindow != true else { return false }
        let panel = PhoneNotificationBannerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let visible = screen.visibleFrame
        let inset = Self.bannerScreenInset
        let card = PhoneNotificationBanner(
            payload: payload, icon: sourceIcon(packageName: payload.packageName),
            width: min(500, visible.width - 2 * inset),
            send: { [weak self] text in
                guard self?.enqueueReply(deviceID: deviceID, eventID: payload.eventId, text: text) == true else {
                    return false
                }
                self?.dismissBanner()
                return true
            },
            markRead: { [weak self] in
                guard self?.enqueueMarkRead(deviceID: deviceID, eventID: payload.eventId) == true else {
                    return false
                }
                self?.dismissBanner()
                return true
            },
            mute: { [weak self] in
                self?.muteSource(deviceID: deviceID, packageName: payload.packageName)
                self?.dismissBanner()
            },
            dismiss: { [weak self] in self?.dismissBanner() },
            beginReply: { [weak panel] in panel?.makeKey() },
            resize: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let panel, self?.banner === panel, let content = panel.contentView else { return }
                    let available = panel.screen?.visibleFrame ?? visible
                    content.layoutSubtreeIfNeeded()
                    let measured = content.fittingSize
                    let width = min(measured.width, available.width - 2 * inset)
                    let height = min(measured.height, available.height - 2 * inset)
                    let frame = NSRect(x: available.maxX - inset - width,
                                       y: available.maxY - inset - height,
                                       width: width, height: height)
                    panel.setFrame(frame, display: true)
                }
            }
        )
        let host = NSHostingView(rootView: card.appTypography())
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        let size = host.fittingSize
        panel.setContentSize(size)
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rightmostX = max(visible.minX, visible.maxX - panel.frame.width)
        let destination = NSPoint(
            x: max(visible.minX, rightmostX - inset),
            y: max(visible.minY, visible.maxY - panel.frame.height - inset)
        )
        let startX = animate ? rightmostX : destination.x
        panel.setFrameOrigin(NSPoint(x: startX, y: destination.y))
        panel.alphaValue = animate ? 0 : 1
        banner = panel
        panel.orderFrontRegardless()
        ClipStore.shared.playReceiveCue()
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.36
                var frame = panel.frame
                frame.origin = destination
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        panel.onResignKey = { [weak self, weak panel] in
            guard let self, let panel, self.banner === panel else { return }
            self.scheduleDismissal(for: panel)
        }
        scheduleDismissal(for: panel)
        return true
    }

    private func scheduleDismissal(for panel: PhoneNotificationBannerPanel) {
        bannerDismissal?.cancel()
        bannerDismissal = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(nanoseconds: Self.bannerTimeout) } catch { return }
            guard let self, let panel, self.banner === panel, !panel.isKeyWindow else { return }
            self.dismissBanner()
        }
    }

    private func dismissBanner() {
        bannerDismissal?.cancel()
        bannerDismissal = nil
        guard let panel = banner else { return }
        banner = nil
        panel.onResignKey = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            showNextBanner()
            return
        }
        bannerIsDismissing = true
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            let screenRight = panel.screen?.visibleFrame.maxX ?? panel.frame.maxX
            let exitX = min(screenRight - panel.frame.width, panel.frame.minX + Self.bannerSlideDistance)
            var frame = panel.frame
            frame.origin.x = exitX
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.bannerIsDismissing = false
                self?.showNextBanner()
            }
        }
    }

    func enqueueReply(deviceID: String, eventID: String, text: String) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventID.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              ClipStore.shared.phoneNotificationRelayEnabled,
              ClipStore.shared.pairedDevices.contains(where: { $0.id == deviceID && $0.securePairing == true }),
              !cleanText.isEmpty, cleanText.utf8.count <= 4_000,
              let expiry = replyableEvents[replyKey(deviceID: deviceID, eventID: eventID)], expiry > Date() else { return false }
        return enqueueCommand(deviceID: deviceID, eventID: eventID, text: cleanText, markAsRead: false)
    }

    func enqueueMarkRead(deviceID: String, eventID: String) -> Bool {
        let key = replyKey(deviceID: deviceID, eventID: eventID)
        guard ClipStore.shared.phoneNotificationRelayEnabled,
              ClipStore.shared.pairedDevices.contains(where: { $0.id == deviceID && $0.securePairing == true }),
              let expiry = markReadableEvents[key], expiry > Date(),
              enqueueCommand(deviceID: deviceID, eventID: eventID, text: "", markAsRead: true) else { return false }
        markReadableEvents.removeValue(forKey: key)
        return true
    }

    private func enqueueCommand(deviceID: String, eventID: String, text: String, markAsRead: Bool) -> Bool {
        let command = PhoneNotificationReplyCommand(
            id: UUID().uuidString.lowercased(), eventId: eventID, text: text, markAsRead: markAsRead
        )
        if let waiter = replyWaiters.first(where: { $0.value.deviceID == deviceID }) {
            replyWaiters.removeValue(forKey: waiter.key)
            waiter.value.continuation.resume(returning: command)
        } else {
            var queue = replyQueues[deviceID] ?? []
            guard queue.count < 16 else { return false }
            queue.append(command)
            replyQueues[deviceID] = queue
        }
        return true
    }

    func waitForReply(deviceID: String) async -> PhoneNotificationReplyCommand? {
        if var queue = replyQueues[deviceID], !queue.isEmpty {
            let command = queue.removeFirst()
            replyQueues[deviceID] = queue
            return command
        }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            replyWaiters[waiterID] = (deviceID, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let waiter = self?.replyWaiters.removeValue(forKey: waiterID) else { return }
                waiter.continuation.resume(returning: nil)
            }
        }
    }

    static let muteActionID = "com.vdx.cliptomac.phoneNotification.mute"
    static let replyActionID = "com.vdx.cliptomac.phoneNotification.reply"
    static let viewActionID = "com.vdx.cliptomac.phoneNotification.view"

    static let markReadActionID = "com.vdx.cliptomac.phoneNotification.markRead"

    private func category(reply: Bool, markRead: Bool, view: Bool) -> String {
        if !markRead {
            switch (reply, view) {
            case (true, true): return "com.vdx.cliptomac.phoneNotification.replyAndView"
            case (true, false): return Self.replyActionID
            case (false, true): return Self.viewActionID
            case (false, false): return "com.vdx.cliptomac.phoneNotification.none"
            }
        }
        return "\(Self.markReadActionID).\(reply).\(view)"
    }

    private func replyKey(deviceID: String, eventID: String) -> String { "\(deviceID):\(eventID)" }
}


private final class PhoneNotificationBannerPanel: NSPanel {
    var onResignKey: (() -> Void)?

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PhoneNotificationBanner: View {
    let payload: PhoneNotificationPayload
    let icon: NSImage?
    let width: CGFloat
    let send: (String) -> Bool
    let markRead: () -> Bool
    let mute: () -> Void
    let dismiss: () -> Void
    let beginReply: () -> Void
    let resize: () -> Void

    @State private var composingReply = false
    @FocusState private var replyFocused: Bool
    @State private var reply = ""
    @State private var replyFailed = false
    @State private var expanded = false
    @State private var markReadFailed = false

    private var preview: String {
        payload.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var canExpandMessage: Bool {
        payload.showFullText == true || payload.body.contains(where: \.isNewline) || preview.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if let icon, payload.packageName == "com.whatsapp" || payload.packageName == "com.whatsapp.w4b" {
                    ZStack {
                        Circle().fill(Color(red: 0.145, green: 0.827, blue: 0.400))
                        Image(nsImage: icon)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                    }
                } else if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "app").font(.title2)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(payload.title.isEmpty ? payload.appName : "\(payload.appName) - \(payload.title)")
                        .font(AppTypography.font(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                        .help("Dismiss")
                        .keyboardShortcut(.cancelAction)
                }
                if !payload.body.isEmpty {
                    if expanded {
                        ScrollView {
                            Text(payload.body).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 150)
                    } else {
                        Text(preview)
                            .font(AppTypography.font(size: 12))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        replyControls
                        notificationActions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        replyControls
                        HStack(spacing: 8) { notificationActions }
                    }
                }
                if replyFailed { Text("Reply could not be sent.").foregroundStyle(.secondary) }
                if markReadFailed { Text("Could not queue Mark as read.").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: composingReply ? width : min(400, width))
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.18, green: 0.13, blue: 0.11),
                                     Color(red: 0.13, green: 0.18, blue: 0.22),
                                     Color(red: 0.19, green: 0.18, blue: 0.12)],
                            startPoint: .leading, endPoint: .trailing
                        ).opacity(0.86))
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .onChange(of: composingReply) { _ in resize() }
        .onChange(of: expanded) { _ in resize() }
        .onChange(of: replyFailed) { _ in resize() }
        .onChange(of: markReadFailed) { _ in resize() }
    }

    @ViewBuilder private var replyControls: some View {
        if composingReply {
            TextField("Reply", text: $reply)
                .textFieldStyle(.plain)
                .font(AppTypography.font(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(red: 0.13, green: 0.55, blue: 0.82)
                            .opacity(replyFocused ? 1 : 0.45), lineWidth: 2)
                }
                .focused($replyFocused)
                .onSubmit(submit)
                .task { replyFocused = true }
                .frame(minWidth: 120)
            Button(action: submit) {
                Image(systemName: "paperplane")
            }
            .buttonStyle(PhoneBannerActionStyle(prominent: true))
            .accessibilityLabel("Send reply")
            .help("Send reply")
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if payload.canReply == true {
            Button {
                beginReply()
                composingReply = true
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .accessibilityLabel("Reply")
            .help("Reply")
            .buttonStyle(PhoneBannerActionStyle())
        }
    }

    @ViewBuilder private var notificationActions: some View {
        if payload.canMarkRead == true {
            Button("Mark as read") { markReadFailed = !markRead() }
                .buttonStyle(PhoneBannerActionStyle())
                .fixedSize()
        }
        Button("Mute", action: mute)
            .buttonStyle(PhoneBannerActionStyle())
            .help("Mute this app on your Mac for 1 hour")
        if canExpandMessage {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .accessibilityLabel(expanded ? "Show less" : "View full message")
            .help(expanded ? "Show less" : "View full message")
            .buttonStyle(PhoneBannerActionStyle())
        }
    }

    private func submit() {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replyFailed = !send(reply)
    }
}

private struct PhoneBannerActionStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.font(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(Color.white.opacity(prominent ? 1 : 0.90))
            .background(
                prominent ? Color(red: 0.00, green: 0.48, blue: 0.94) : Color.black.opacity(0.42),
                in: Capsule()
            )
            .opacity(!isEnabled ? 0.48 : configuration.isPressed ? 0.72 : 1)
    }
}
