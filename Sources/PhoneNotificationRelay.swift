import Foundation
import CryptoKit
import UserNotifications

struct PhoneNotificationPayload: Decodable {
    let eventId: String
    let appName: String
    let packageName: String
    let title: String
    let body: String
    let timestamp: Int64
    let canReply: Bool?
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
}

@MainActor
final class PhoneNotificationRelay {
    static let shared = PhoneNotificationRelay()

    enum Result { case delivered, ignored, rateLimited }

    private struct SeenEvent {
        let digest: String
        let date: Date
    }

    private var seen: [String: SeenEvent] = [:]
    private var recentEvents: [String: [Date]] = [:]
    private var replyableEvents: [String: Date] = [:]
    private var replyQueues: [String: [PhoneNotificationReplyCommand]] = [:]
    private var replyWaiters: [UUID: (deviceID: String, continuation: CheckedContinuation<PhoneNotificationReplyCommand?, Never>)] = [:]

    func registerNotificationActions() {
        let center = UNUserNotificationCenter.current()
        let reply = UNTextInputNotificationAction(identifier: Self.replyActionID, title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let view = UNNotificationAction(identifier: Self.viewActionID, title: "View full message", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryNone, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.categoryView, actions: [view], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.categoryReply, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.categoryReplyAndView, actions: [reply, view], intentIdentifiers: [], options: [])
        ])
    }

    func receive(_ payload: PhoneNotificationPayload, from device: PairedDevice) -> Result {
        guard payload.isValid else { return .ignored }
        guard ClipStore.shared.phoneNotificationRelayEnabled else { return .ignored }

        let now = Date()
        let scopedID = String(SHA256.hash(data: Data(device.id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)) + "-" + payload.eventId
        let content = "\(payload.appName)\u{0}\(payload.title)\u{0}\(payload.body)\u{0}\(payload.canReply == true)\u{0}\(payload.showFullText == true)"
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        if let previous = seen[scopedID], previous.digest == digest { return .ignored }

        let recent = (recentEvents[device.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 40 else { recentEvents[device.id] = recent; return .rateLimited }
        recentEvents[device.id] = recent + [now]
        replyableEvents = replyableEvents.filter { $0.value > now }
        if payload.canReply == true {
            replyableEvents[replyKey(deviceID: device.id, eventID: payload.eventId)] = now.addingTimeInterval(15 * 60)
        }

        seen[scopedID] = SeenEvent(digest: digest, date: now)
        if seen.count > 512 {
            let expired = seen.filter { now.timeIntervalSince($0.value.date) > 3600 }.map(\.key)
            expired.forEach { seen.removeValue(forKey: $0) }
            if seen.count > 512, let oldest = seen.min(by: { $0.value.date < $1.value.date })?.key { seen.removeValue(forKey: oldest) }
        }

        let notification = UNMutableNotificationContent()
        notification.title = payload.appName
        notification.subtitle = payload.title
        notification.body = payload.body
        notification.threadIdentifier = payload.packageName
        notification.sound = .default
        let wantsReply = payload.canReply == true
        let wantsFullText = payload.showFullText == true
        notification.categoryIdentifier = category(reply: wantsReply, view: wantsFullText)
        notification.userInfo = [
            "deviceID": device.id,
            "eventID": payload.eventId,
            "appName": payload.appName,
            "sourceTitle": payload.title,
            "fullBody": payload.body,
            "canReply": wantsReply,
            "showFullText": wantsFullText
        ]
        // Focus allowlists are controlled by macOS and cannot be inspected by the app.
        notification.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: scopedID, content: notification, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [scopedID])
        center.removeDeliveredNotifications(withIdentifiers: [scopedID])
        center.add(request) { _ in }
        return .delivered
    }

    func enqueueReply(deviceID: String, eventID: String, text: String) -> Bool {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventID.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              ClipStore.shared.phoneNotificationRelayEnabled,
              ClipStore.shared.pairedDevices.contains(where: { $0.id == deviceID && $0.securePairing == true }),
              !cleanText.isEmpty, cleanText.utf8.count <= 4_000,
              let expiry = replyableEvents[replyKey(deviceID: deviceID, eventID: eventID)], expiry > Date() else { return false }
        let command = PhoneNotificationReplyCommand(id: UUID().uuidString.lowercased(), eventId: eventID, text: cleanText)
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

    static let replyActionID = "com.vdx.cliptomac.phoneNotification.reply"
    static let viewActionID = "com.vdx.cliptomac.phoneNotification.view"

    private static let categoryNone = "com.vdx.cliptomac.phoneNotification.none"
    private static let categoryView = "com.vdx.cliptomac.phoneNotification.view"
    private static let categoryReply = "com.vdx.cliptomac.phoneNotification.reply"
    private static let categoryReplyAndView = "com.vdx.cliptomac.phoneNotification.replyAndView"

    private func category(reply: Bool, view: Bool) -> String {
        switch (reply, view) {
        case (true, true): Self.categoryReplyAndView
        case (true, false): Self.categoryReply
        case (false, true): Self.categoryView
        case (false, false): Self.categoryNone
        }
    }

    private func replyKey(deviceID: String, eventID: String) -> String { "\(deviceID):\(eventID)" }
}
