import Foundation
import AppKit
import UserNotifications
import Combine
import CryptoKit

public struct PairedDevice: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let token: String
    public let pairedAt: Date
    public let securePairing: Bool?
    
    public init(id: String, name: String, token: String, pairedAt: Date = Date(), securePairing: Bool? = nil) {
        self.id = id
        self.name = name
        self.token = token
        self.pairedAt = pairedAt
        self.securePairing = securePairing
    }
}

@MainActor
public class ClipStore: ObservableObject {
    public static let shared = ClipStore()
    
    @Published public var clips: [ClipItem] = []
    @Published public var autoCopy: Bool {
        didSet { preferences.set(autoCopy, forKey: "autoCopy") }
    }
    @Published public var showNotifications: Bool {
        didSet { preferences.set(showNotifications, forKey: "showNotifications") }
    }
    @Published public var phoneNotificationRelayEnabled: Bool {
        didSet {
            preferences.set(phoneNotificationRelayEnabled, forKey: "phoneNotificationRelayEnabled")
        }
    }
    @Published var showSourceAppBanners = false {
        didSet { preferences.set(showSourceAppBanners, forKey: "showPhoneNotificationsInAppBanner") }
    }
    @Published public var phoneNotificationPermissionMessage: String?
    @Published public var phoneNotificationSettingsPromptRequested = false
    @Published public var playSound: Bool {
        didSet { preferences.set(playSound, forKey: "playSound") }
    }
    @Published public var launchAtLogin: Bool {
        didSet { LaunchAtLoginManager.shared.setEnabled(launchAtLogin) }
    }
    @Published public var localIP: String = "127.0.0.1"
    @Published public var port: Int = 5678
    @Published public var lastReceivedAt: Date? = nil
    
    // Multi-Device Pairing Management
    @Published public var pairedDevices: [PairedDevice] = []
    @Published private var deviceLastSeen: [String: Date] = [:]
    @Published private var presenceTick = 0
    private var presenceTimer: Timer?

    public func markDeviceSeen(id: String, at date: Date = Date()) {
        guard pairedDevices.contains(where: { $0.id == id && $0.securePairing == true }) else { return }
        deviceLastSeen[id] = date
    }
    private var devicePresence: DevicePresencePresentation { DevicePresencePresentation(devices: pairedDevices, lastSeen: deviceLastSeen) }
    public func connectionState(at now: Date = Date()) -> DeviceConnectionState { devicePresence.state(at: now) }
    public var connectionSummary: String {
        devicePresence.summary()
    }
    public var connectionExplanation: String {
        devicePresence.explanation()
    }
    @Published public var undoAvailable = false
    @Published public var attachmentDirectory: URL
    @Published public var shortcutKeyCode: UInt32 {
        didSet { preferences.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode"); NotificationCenter.default.post(name: .clipShortcutChanged, object: nil) }
    }
    @Published public var shortcutModifiers: UInt32 {
        didSet { preferences.set(Int(shortcutModifiers), forKey: "shortcutModifiers"); NotificationCenter.default.post(name: .clipShortcutChanged, object: nil) }
    }
    
    public var hasPairedDevices: Bool {
        !pairedDevices.isEmpty
    }
    
    public var hasPairedDevice: Bool {
        !pairedDevices.isEmpty
    }
    
    public var pairedDeviceName: String {
        pairedDevicesSummary
    }
    
    public var pairedDevicesSummary: String {
        if pairedDevices.isEmpty { return "" }
        if pairedDevices.count == 1 { return pairedDevices[0].name }
        return "\(pairedDevices.count) Devices (\(pairedDevices.map { $0.name }.joined(separator: ", ")))"
    }
    
    @Published public var deleteStoredFilesByDefault = false { didSet { preferences.set(deleteStoredFilesByDefault, forKey: "deleteStoredFiles") } }
    private let preferences: SQLitePreferences
    private lazy var phoneNotificationPermissionController = PhoneNotificationPermissionController(
        preferences: preferences,
        relayIsEnabled: { [weak self] in self?.phoneNotificationRelayEnabled ?? false },
        setRelayEnabled: { [weak self] enabled in self?.phoneNotificationRelayEnabled = enabled },
        setPermissionMessage: { [weak self] message in self?.phoneNotificationPermissionMessage = message },
        requestSettingsPrompt: { [weak self] in self?.phoneNotificationSettingsPromptRequested = true }
    )
    private let attachmentDeletionScheduler: AttachmentDeletionScheduler
    private let storageURL: URL
    private let credentialStorage: TrustedDeviceStorage?
    private let trustedDevicesURL: URL
    private let seenTransferIDsURL: URL
    private let historyFiles: ClipHistoryFileStore
    private var seenTransferIDs = Set<String>()
    
    public init(storageDirectory: URL? = nil, preferences: UserDefaults = .standard, systemIntegration: Bool = true) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = storageDirectory ?? appSupport.appendingPathComponent("ClipToMac", isDirectory: true)
        try? PrivateAppStorage.prepare(dir)
        let preferences = SQLitePreferences(directory: dir, legacy: preferences)
        self.preferences = preferences
        self.showSourceAppBanners = preferences.bool(forKey: "showPhoneNotificationsInAppBanner")
        self.attachmentDeletionScheduler = AttachmentDeletionScheduler(preferences: preferences)
        self.deleteStoredFilesByDefault = preferences.bool(forKey: "deleteStoredFiles")
        self.autoCopy = preferences.object(forKey: "autoCopy") as? Bool ?? true
        self.showNotifications = preferences.object(forKey: "showNotifications") as? Bool ?? true
        // Ignore the earlier pre-permission preference values once, so a stale
        // enabled switch cannot survive without this version's permission flow.
        let notificationRelayConsentConfirmed = preferences.integer(forKey: "phoneNotificationRelayConsentVersion") >= 1
        self.phoneNotificationRelayEnabled = notificationRelayConsentConfirmed && preferences.bool(forKey: "phoneNotificationRelayEnabled")
        if !notificationRelayConsentConfirmed {
            preferences.set(false, forKey: "phoneNotificationRelayEnabled")
        }
        self.playSound = preferences.object(forKey: "playSound") as? Bool ?? true
        self.launchAtLogin = LaunchAtLoginManager.shared.isEnabled
        
        self.storageURL = dir.appendingPathComponent("history.json")
        self.trustedDevicesURL = dir.appendingPathComponent("trusted_devices.json")
        self.credentialStorage = systemIntegration ? TrustedDeviceStorage(url: self.trustedDevicesURL) : nil
        self.seenTransferIDsURL = dir.appendingPathComponent("seen_transfer_ids.json")
        let savedAttachment = preferences.string(forKey: "attachmentDirectory")
        self.attachmentDirectory = savedAttachment.map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent("attachments", isDirectory: true)
        self.historyFiles = ClipHistoryFileStore(historyURL: self.storageURL, seenTransferIDsURL: self.seenTransferIDsURL)
        self.seenTransferIDs = historyFiles.loadSeenTransferIDs()
        let savedKey = preferences.integer(forKey: "shortcutKeyCode")
        let savedModifiers = preferences.integer(forKey: "shortcutModifiers")
        self.shortcutKeyCode = UInt32(savedKey == 0 ? 9 : savedKey)
        self.shortcutModifiers = UInt32(savedModifiers == 0 ? 0x100 | 0x800 : savedModifiers)
        
        loadTrustedDevices()
        loadClips()
        repairAttachmentExtensions()
        sweepAttachmentDeletions()
        if systemIntegration {
            updateLocalIP(); refreshPhoneNotificationPermission()
            presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.presenceTick += 1 }
            }
        }
    }
    
    public func updateLocalIP() {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        self.localIP = address
    }
    
    // MARK: - Multi-Device Pairing Management
    @discardableResult public func saveTrustedDevice(id: String, name: String, token: String, securePairing: Bool = false) -> Bool {
        let previous = pairedDevices
        deviceLastSeen.removeValue(forKey: id)
        pairedDevices.removeAll { $0.id == id || $0.token == token }
        let newDevice = PairedDevice(id: id, name: name, token: token, securePairing: securePairing)
        pairedDevices.append(newDevice)
        guard saveTrustedDevices() else { pairedDevices = previous; return false }
        sendSystemNotification(title: "Device Paired", body: "Successfully paired with \(name)")
        return true
    }
    
    public func migrateDeviceIdentity(token: String, id: String) -> Bool {
        guard id.range(of: "^android-[a-f0-9]{16}$", options: .regularExpression) != nil,
              let index = pairedDevices.firstIndex(where: { $0.token == token }),
              !pairedDevices.contains(where: { $0.id == id && $0.token != token }) else { return false }
        let old = pairedDevices[index]
        if old.id == id { return true }
        pairedDevices[index] = PairedDevice(id: id, name: old.name, token: token, pairedAt: old.pairedAt, securePairing: old.securePairing)
        guard saveTrustedDevices() else { pairedDevices[index] = old; return false }
        for i in clips.indices where clips[i].sourceDeviceId == old.id { clips[i].sourceDeviceId = id }
        saveClips()
        return true
    }

    @discardableResult public func unpairDevice(id: String? = nil) -> Bool {
        let previous = pairedDevices
        if let id { pairedDevices.removeAll { $0.id == id } } else { pairedDevices.removeAll() }
        guard saveTrustedDevices() else { pairedDevices = previous; return false }
        return true
    }

    public func unpairAll() { unpairDevice() }

    public func validateToken(_ token: String) -> Bool {
        !token.isEmpty && pairedDevices.contains(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token })
    }

    @discardableResult private func saveTrustedDevices() -> Bool {
        do {
            if let credentialStorage { try credentialStorage.save(pairedDevices) }
            else { try PrivateAppStorage.write(JSONEncoder().encode(pairedDevices), to: trustedDevicesURL) }
            return true
        } catch { return false }
    }

    private func loadTrustedDevices() {
        if let credentialStorage { pairedDevices = (try? credentialStorage.load()) ?? []; return }
        if let data = try? Data(contentsOf: trustedDevicesURL), let loaded = try? JSONDecoder().decode([PairedDevice].self, from: data) { pairedDevices = loaded }
    }

    // MARK: - Clips
    public func addClips(items: [(text: String, appName: String, packageName: String, timestamp: Date)]) {
        var addedAny = false
        for item in items.reversed() {
            let cleanText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty else { continue }
            if let index = clips.firstIndex(where: { $0.kind == .text && $0.text == cleanText }) { clips[index].repeatCount += 1; clips[index].updatedAt = Date(); continue }
            
            let clip = ClipItem(text: cleanText, appName: item.appName, packageName: item.packageName, timestamp: item.timestamp)
            clips.insert(clip, at: 0)
            addedAny = true
        }
        
        if addedAny {
            saveClips()
            lastReceivedAt = Date()
            
            if autoCopy, let latest = clips.first {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(latest.text, forType: .string)
            }
            playReceiveCue()
            if showNotifications, let latest = clips.first {
                sendNotification(for: latest)
            }
        }
    }
    
    public func addClip(text: String, appName: String, packageName: String) {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return }
        
        if let index = clips.firstIndex(where: { $0.kind == .text && $0.text == cleanText }) {
            clips[index].repeatCount += 1; clips[index].updatedAt = Date(); saveClips(); return
        }
        
        let item = ClipItem(text: cleanText, appName: appName, packageName: packageName, timestamp: Date())
        clips.insert(item, at: 0)
        
        saveClips()
        lastReceivedAt = Date()
        
        if autoCopy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(cleanText, forType: .string)
        }
        
        playReceiveCue()
        
        if showNotifications {
            sendNotification(for: item)
        }
    }
    
    func playReceiveCue() {
        guard playSound, let cue = NSSound(named: "Pop")?.copy() as? NSSound else { return }
        cue.volume = 0.25
        cue.play()
    }

    @discardableResult public func copyImageToClipboard(_ item: ClipItem) -> Bool {
        guard item.kind == .image, let path = item.attachmentPath else { return false }
        return AttachmentClipboard.copyImage(at: URL(fileURLWithPath: path))
    }

    public func copyToClipboard(_ item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
    }

    @discardableResult
    public func addTransferredItem(id: String, text: String, appName: String, packageName: String, timestamp: Date, kind: String, mimeType: String? = nil, attachmentName: String? = nil, attachmentPath: String? = nil, direction: String = "received", sourceDeviceId: String? = nil, contentHash: String? = nil) -> Bool {
        guard !id.isEmpty, let clipKind = ClipKind(rawValue: kind) else { return false }
        if seenTransferAttempt(id) { return true }
        if clips.contains(where: { $0.transferID == id }) { return persistSeenTransferAttempt(id) }
        var updatedClips = clips
        let clean = text
        guard clipKind != .text || !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let signature = contentHash?.lowercased() ?? contentDigest(kind: clipKind, text: clean, path: attachmentPath, name: attachmentName)
        if let index = clips.firstIndex(where: { $0.kind == clipKind && $0.appName == appName && $0.direction == direction && $0.sourceDeviceId == sourceDeviceId && ($0.contentHash ?? contentDigest(kind: $0.kind, text: $0.text, path: $0.attachmentPath, name: $0.attachmentName)) == signature }) {
            updatedClips[index].repeatCount += 1; updatedClips[index].updatedAt = Date(); updatedClips[index].transferID = id
            return persistSeenTransferAttempt(id, clips: updatedClips)
        }
        updatedClips.insert(ClipItem(text: clean, appName: appName, packageName: packageName, timestamp: timestamp, kind: clipKind, mimeType: mimeType, attachmentName: attachmentName, attachmentPath: attachmentPath, sourceDeviceId: sourceDeviceId, direction: direction, transferID: id, contentHash: signature), at: 0)
        guard persistSeenTransferAttempt(id, clips: updatedClips) else { return false }
        lastReceivedAt = Date()
        if autoCopy && clipKind == .text { copyToClipboard(clips[0]) }
        playReceiveCue()
        if showNotifications { sendNotification(for: clips[0]) }
        return true
    }

    /// Returns true when this transfer ID is already committed to local history.
    public func seenTransferAttempt(_ id: String) -> Bool {
        seenTransferIDs.contains(id)
    }
    private func persistSeenTransferAttempt(_ id: String, clips updatedClips: [ClipItem]? = nil) -> Bool {
        guard let updated = historyFiles.recordSeenTransferAttempt(id, current: seenTransferIDs, clips: updatedClips) else { return false }
        seenTransferIDs = updated
        if let updatedClips { clips = updatedClips }
        return true
    }
    private func contentDigest(kind: ClipKind, text: String, path: String?, name: String?) -> String {
        let data: Data
        if kind == .text { data = Data(text.utf8) }
        else if let path, let bytes = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) { data = bytes }
        else { data = Data((name ?? "").utf8) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func markOutboundDelivered(ids: [String]) {
        let set = Set(ids); for i in clips.indices where set.contains(clips[i].transferID) { clips[i].deliveryState = "delivered"; clips[i].updatedAt = Date() }; saveClips()
    }
    public var storageDirectory: URL { storageURL.deletingLastPathComponent() }
    public var storageBytes: Int64 {
        historyFiles.storageBytes(attachmentDirectory: attachmentDirectory)
    }
    public func setAttachmentDirectory(_ url: URL) { attachmentDirectory = url; preferences.set(url.path, forKey: "attachmentDirectory"); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    private var deletedClips: [ClipItem] = []
    private var undoGeneration = UUID()
    public func removeClips(ids: Set<UUID>, deleteFiles: Bool? = nil) {
        let removed = clips.filter { ids.contains($0.id) }; guard !removed.isEmpty else { return }
        let previous = clips
        if deleteFiles ?? deleteStoredFilesByDefault {
            attachmentDeletionScheduler.schedule(for: removed, attachmentDirectory: attachmentDirectory)
        }
        clips.removeAll { ids.contains($0.id) }
        guard saveClips() else { clips = previous; return }
        deletedClips = removed; undoGeneration = UUID(); let generation = undoGeneration; undoAvailable = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if self.undoGeneration == generation { self.undoAvailable = false; self.deletedClips = [] }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.1) { self.sweepAttachmentDeletions() }
    }
    public func undoDelete() {
        guard undoAvailable else { return }
        attachmentDeletionScheduler.cancel(for: deletedClips)
        clips = (deletedClips + clips).sorted { $0.timestamp > $1.timestamp }; deletedClips = []; undoAvailable = false; undoGeneration = UUID(); saveClips()
    }
    private func sweepAttachmentDeletions() {
        let references = Set(clips.compactMap { $0.attachmentPath }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path })
        if attachmentDeletionScheduler.sweepExpired(referencedFiles: references, attachmentDirectory: attachmentDirectory) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.sweepAttachmentDeletions() }
        }
    }
    public func togglePinned(ids: Set<UUID>) { for i in clips.indices where ids.contains(clips[i].id) { clips[i].isPinned.toggle(); clips[i].updatedAt = Date() }; saveClips() }
    public func setCollection(_ name: String?, ids: Set<UUID>) { for i in clips.indices where ids.contains(clips[i].id) { clips[i].collection = name; clips[i].updatedAt = Date() }; saveClips() }
    public func exportBackup(to url: URL, items selectedItems: [ClipItem]? = nil) throws {
        try LibraryBackupArchive.export(selectedItems ?? clips, to: url)
    }
    public func importBackup(from url: URL) throws {
        let prepared = try LibraryBackupArchive.prepareImport(
            from: url,
            existingIDs: Set(clips.map(\.id)),
            attachmentDirectory: attachmentDirectory
        )
        let previous = clips
        clips = (prepared.clips + clips).sorted { $0.timestamp > $1.timestamp }
        guard saveClips() else {
            clips = previous
            LibraryBackupArchive.discard(prepared)
            throw NSError(domain: "ClipToMac", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not save imported clips to the library."])
        }
    }
    public func recordOutbound(text: String, fileURL: URL? = nil, to device: PairedDevice, transferID: String, kind: ClipKind? = nil, mimeType: String? = nil, contentHash: String? = nil, attachmentName: String? = nil) -> Bool {
        guard !transferID.isEmpty else { return false }
        if clips.contains(where: { $0.transferID == transferID }) { return true }
        let resolvedKind = kind ?? (fileURL == nil ? .text : .file)
        let signature = contentHash ?? contentDigest(kind: resolvedKind, text: text, path: fileURL?.path, name: fileURL?.lastPathComponent)
        if let index = clips.firstIndex(where: { $0.direction == "sent" && $0.sourceDeviceId == device.id && $0.kind == resolvedKind && ($0.contentHash ?? contentDigest(kind: $0.kind, text: $0.text, path: $0.attachmentPath, name: $0.attachmentName)) == signature }) {
            clips[index].repeatCount += 1; clips[index].updatedAt = Date(); clips[index].transferID = transferID; clips[index].deliveryState = "queued"
            return saveClips()
        }
        var storedURL = fileURL
        if let source = fileURL {
            do {
                try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
                let root = attachmentDirectory.standardizedFileURL.path + "/"
                if !source.standardizedFileURL.path.hasPrefix(root) {
                    let target = attachmentDirectory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: target); storedURL = target
                }
            }
            catch { return false }
        }
        clips.insert(ClipItem(text: text, appName: "This Mac", packageName: "com.vdx.cliptomac", kind: resolvedKind, mimeType: mimeType, attachmentName: attachmentName ?? fileURL?.lastPathComponent, attachmentPath: storedURL?.path, sourceDeviceId: device.id, direction: "sent", transferID: transferID, deliveryState: "queued", contentHash: signature), at: 0); return saveClips()
    }
    
    public func removeClip(_ item: ClipItem) {
        removeClips(ids: [item.id])
    }
    
    public func clearAll() {
        removeClips(ids: Set(clips.map(\.id)))
    }
    
    @discardableResult private func saveClips() -> Bool {
        historyFiles.saveClips(clips)
    }
    
    private func repairAttachmentExtensions() {
        clips = historyFiles.repairAttachmentExtensions(in: clips, attachmentDirectory: attachmentDirectory)
    }

    private func loadClips() {
        clips = historyFiles.loadClips()
    }
    
    public func setPhoneNotificationRelayEnabled(_ enabled: Bool) {
        phoneNotificationPermissionController.setRelayEnabledByUser(enabled)
    }

    public func openPhoneNotificationSettings() {
        phoneNotificationPermissionController.openNotificationSettings()
    }

    public func openFocusSettings() {
        phoneNotificationPermissionController.openFocusSettings()
    }

    public func refreshPhoneNotificationPermission() {
        phoneNotificationPermissionController.refresh()
    }
    
    private func sendNotification(for item: ClipItem) {
        let content = UNMutableNotificationContent()
        content.title = "Received from \(item.appName)"
        content.body = item.text.count > 100 ? String(item.text.prefix(100)) + "..." : item.text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func sendSystemNotification(title: String, body: String) {
        guard showNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
