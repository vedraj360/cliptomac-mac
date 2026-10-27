import Foundation
import Combine
import CryptoKit
import AppKit

private struct OutboundRecord: Codable {
    var paused: Bool? = nil
    var transferId: String
    var deviceId: String
    var deviceName: String
    var kind: String
    var mimeType: String
    var name: String
    var text: String
    var app: String
    var package: String
    var timestamp: Int64
    var size: Int64
    var sha256: String
    var attachmentPath: String?
}

@MainActor
public final class MacTransferService: ObservableObject {
    public static let shared = MacTransferService()
    public static let maxBytes: Int64 = 25 * 1024 * 1024
    @Published public private(set) var outboundItems: [FileTransferStatus] = []
    @Published public private(set) var incomingItems: [FileTransferStatus] = []
    private var records: [OutboundRecord] = []
    private var rates = TransferRateEstimator()
    private var servedBuckets: [String: Set<Int>] = [:]
    private var cancelled = Set<String>()
    private var inboxWaiters: [UUID: (token: String, continuation: CheckedContinuation<[[String: Any]]?, Never>)] = [:]

    public func waitForInbox(token: String) async -> [[String: Any]]? {
        guard let current = inbox(token: token) else { return nil }
        if !current.isEmpty { return current }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            inboxWaiters[id] = (token, continuation)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if let waiter = inboxWaiters.removeValue(forKey: id) { waiter.continuation.resume(returning: inbox(token: waiter.token)) }
            }
        }
    }

    private func wakeInboxWaiters(deviceID: String) {
        let matching = inboxWaiters.filter { entry in ClipStore.shared.pairedDevices.first(where: { $0.token == entry.value.token })?.id == deviceID }.map(\.key)
        for id in matching { if let waiter = inboxWaiters.removeValue(forKey: id) { waiter.continuation.resume(returning: inbox(token: waiter.token)) } }
    }
    private let fileURL: URL

    init() {
        #if CLIPTOMAC_TRANSFER_TEST
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("ClipToMac-transfer-test-\(UUID().uuidString)", isDirectory: true)
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipToMac", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("transfer-inbox.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([OutboundRecord].self, from: data) {
            records = saved
            outboundItems = saved.map { record in FileTransferStatus(id: record.transferId, deviceID: record.deviceId, deviceName: record.deviceName, name: record.name.isEmpty ? "Text" : record.name, bytesSent: 0, totalBytes: record.size, state: record.paused == true ? "paused" : "queued", error: nil, createdAt: Date(timeIntervalSince1970: Double(record.timestamp) / 1000)) }
        }
    }

    @discardableResult
    public func sendText(_ text: String, to device: PairedDevice) throws -> String {
        guard ClipStore.shared.pairedDevices.contains(where: { $0.securePairing == true && $0.id == device.id && $0.token == device.token && !$0.token.isEmpty }) else { throw TransferError.invalidDevice }
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes else { throw TransferError.invalidSize }
        let digest = Self.sha256(bytes)
        if let pending = records.first(where: { $0.deviceId == device.id && $0.kind == "text" && $0.sha256 == digest }) { return pending.transferId }
        let id = UUID().uuidString
        let record = OutboundRecord(transferId: id, deviceId: device.id, deviceName: device.name, kind: "text", mimeType: "text/plain", name: "", text: text, app: Host.current().localizedName ?? "Mac", package: "", timestamp: Int64(Date().timeIntervalSince1970 * 1000), size: Int64(bytes.count), sha256: Self.sha256(bytes), attachmentPath: nil)
        try add(record)
        _ = ClipStore.shared.recordOutbound(text: text, fileURL: nil, to: device, transferID: id, kind: .text, mimeType: "text/plain")
        outboundItems.append(FileTransferStatus(id: id, deviceID: device.id, deviceName: device.name, name: "Text", bytesSent: Int64(bytes.count), totalBytes: Int64(bytes.count), state: "queued", error: nil, createdAt: Date()))
        return id
    }

    @discardableResult
    public func sendFile(_ url: URL, to device: PairedDevice) async throws -> String {
        guard ClipStore.shared.pairedDevices.contains(where: { $0.securePairing == true && $0.id == device.id && $0.token == device.token && !$0.token.isEmpty }) else { throw TransferError.invalidDevice }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size >= 0 else { throw TransferError.invalidSize }
        let digest = try await Task.detached { try TransferVerifier.digest(file: url) }.value
        if let pending = records.first(where: { $0.deviceId == device.id && $0.kind != "text" && $0.sha256 == digest }) { return pending.transferId }
        let id = UUID().uuidString
        let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        let name = url.lastPathComponent
        let copied = ClipStore.shared.attachmentDirectory.appendingPathComponent(UUID().uuidString + "." + String(url.pathExtension.prefix(12)))
        try FileManager.default.createDirectory(at: ClipStore.shared.attachmentDirectory, withIntermediateDirectories: true)
        try await Task.detached {
            guard try TransferVerifier.availableBytes(at: copied.deletingLastPathComponent()) >= size else { throw BucketError.invalid("Not enough storage on Mac") }
            try FileManager.default.copyItem(at: url, to: copied)
            guard try copied.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size), try TransferVerifier.digest(file: copied) == digest else { try? FileManager.default.removeItem(at: copied); throw BucketError.invalid("Source changed while preparing transfer") }
        }.value
        guard ClipStore.shared.pairedDevices.contains(where: { $0.securePairing == true && $0.id == device.id && $0.token == device.token }) else { try? FileManager.default.removeItem(at: copied); throw TransferError.invalidDevice }
        if let pending = records.first(where: { $0.deviceId == device.id && $0.kind != "text" && $0.sha256 == digest }) { try? FileManager.default.removeItem(at: copied); return pending.transferId }
        let record = OutboundRecord(transferId: id, deviceId: device.id, deviceName: device.name, kind: mime.hasPrefix("image/") ? "image" : "file", mimeType: mime, name: name, text: "", app: Host.current().localizedName ?? "Mac", package: "", timestamp: Int64(Date().timeIntervalSince1970 * 1000), size: size, sha256: digest, attachmentPath: copied.path)
        do { try add(record) } catch { try? FileManager.default.removeItem(at: copied); throw error }
        _ = ClipStore.shared.recordOutbound(text: "", fileURL: copied, to: device, transferID: id, kind: mime.hasPrefix("image/") ? .image : .file, mimeType: mime, contentHash: digest, attachmentName: name)
        outboundItems.append(FileTransferStatus(id: id, deviceID: device.id, deviceName: device.name, name: name, bytesSent: 0, totalBytes: size, state: "queued", error: nil, createdAt: Date()))
        return id
    }

    func updateIncoming(_ manifest: TransferManifest, device: PairedDevice, bytes: Int64) {
        let id = String(TransferVerifier.digest(Data(device.id.utf8)).prefix(16)) + "-" + manifest.transferId
        let previous = incomingItems.first(where: { $0.id == id })
        if let previous, ["verifying", "complete", "cancelled"].contains(previous.state) { return }
        let value = max(previous?.bytesSent ?? 0, bytes)
        let sample = rates.sample(id, bytes: value, total: manifest.size)
        let item = FileTransferStatus(id: id, deviceID: device.id, deviceName: device.name, name: manifest.name, bytesSent: value, totalBytes: manifest.size, state: "receiving", error: nil, createdAt: previous?.createdAt ?? Date(), bytesPerSecond: sample.0, estimatedSecondsRemaining: sample.1, direction: "received")
        incomingItems.removeAll { $0.id == id }; incomingItems.append(item)
        incomingItems = Array(incomingItems.suffix(50))
    }
    func incomingState(owner: String, transferID: String, state: String, error: String? = nil) {
        if ["complete", "cancelled", "failed"].contains(state) { IncomingByteProgress.shared.finish(owner: owner, id: transferID) }
        let id = String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-" + transferID
        guard let index = incomingItems.firstIndex(where: { $0.id == id }) else { return }
        let old = incomingItems[index]; rates.reset(id)
        incomingItems[index] = FileTransferStatus(id: id, deviceID: old.deviceID, deviceName: old.deviceName, name: old.name, bytesSent: state == "complete" ? old.totalBytes : old.bytesSent, totalBytes: old.totalBytes, state: state, error: error, createdAt: old.createdAt, direction: "received")
    }

    func migrateOwner(from old: String, to new: String) {
        guard old != new else { return }
        let previous = records
        for i in records.indices where records[i].deviceId == old { records[i].deviceId = new }
        do { try persistThrowing() } catch { records = previous }
    }

    public func togglePause(id: String) {
        guard let index = records.firstIndex(where: { $0.transferId == id }) else { return }
        let previous = records[index].paused
        records[index].paused = previous != true
        do { try persistThrowing() } catch { records[index].paused = previous; return }
        setStatus(id: id, state: records[index].paused == true ? "paused" : "queued")
        if records[index].paused != true { wakeInboxWaiters(deviceID: records[index].deviceId) }
    }

    public func cancel(id: String) {
        let previous = records
        records.removeAll { $0.transferId == id }
        do { try persistThrowing() } catch { records = previous; return }
        cancelled.insert(id)
        setStatus(id: id, state: "cancelled")
    }

    public func updateProgress(id: String, bytes: Int64) { if records.first(where: { $0.transferId == id })?.paused == true { return }; let total = outboundItems.first(where: { $0.id == id })?.totalBytes ?? 0; setStatus(id: id, state: bytes >= total ? "verifying on phone" : "sending", bytes: bytes) }
    private func setStatus(id: String, state: String, bytes: Int64? = nil) {
        guard let i = outboundItems.firstIndex(where: { $0.id == id }) else { return }
        let old = outboundItems[i]
        let progress = bytes ?? old.bytesSent
        let sample: (Double, Double?)
        if state == "sending" { sample = rates.sample(id, bytes: progress, total: old.totalBytes) }
        else { rates.reset(id); sample = (0, nil) }
        outboundItems[i] = FileTransferStatus(id: old.id, deviceID: old.deviceID, deviceName: old.deviceName, name: old.name, bytesSent: bytes ?? old.bytesSent, totalBytes: old.totalBytes, state: state, error: nil, createdAt: old.createdAt, bytesPerSecond: sample.0, estimatedSecondsRemaining: sample.1)
    }

    public func inbox(token: String) -> [[String: Any]]? {
        guard let device = ClipStore.shared.pairedDevices.first(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token }) else { return nil }
        let items = records.filter { $0.deviceId == device.id && $0.paused != true }.map { r -> [String: Any] in
            ["transferId": r.transferId, "deviceId": r.deviceId, "kind": r.kind, "mimeType": r.mimeType, "name": r.name, "text": r.text, "app": r.app, "package": r.package, "timestamp": r.timestamp, "size": r.size, "sha256": r.sha256, "transferProtocol": 2]
        }
        return items
    }

    public func download(transferID: String, token: String) -> URL? {
        guard let device = ClipStore.shared.pairedDevices.first(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token }),
              let record = records.first(where: { $0.transferId == transferID && $0.deviceId == device.id && $0.paused != true }),
              let path = record.attachmentPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    func bucketManifest(id: String, token: String) -> TransferManifest? {
        guard let device = ClipStore.shared.pairedDevices.first(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token }),
              let record = records.first(where: { $0.transferId == id && $0.deviceId == device.id && $0.paused != true && $0.kind != "text" }) else { return nil }
        return TransferManifest(protocolVersion: 2, transferId: record.transferId, size: record.size, bucketSize: TransferManifest.bucketBytes, sha256: record.sha256, kind: record.kind, mimeType: record.mimeType, name: record.name, app: record.app, package: record.package, timestamp: record.timestamp)
    }
    func updateBucketProgress(id: String, index: Int, manifest: TransferManifest) {
        servedBuckets[id, default: []].insert(index)
        let bytes = servedBuckets[id, default: []].reduce(Int64(0)) { $0 + Int64((try? manifest.length($1)) ?? 0) }
        updateProgress(id: id, bytes: bytes)
    }

    public func acknowledge(ids: [String], token: String) -> Bool {
        guard let device = ClipStore.shared.pairedDevices.first(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token }) else { return false }
        let authorizedIDs = records.filter { ids.contains($0.transferId) && $0.deviceId == device.id }.map(\.transferId)
        let previous = records
        records.removeAll { authorizedIDs.contains($0.transferId) }
        do { try persistThrowing() } catch { records = previous; return false }
        ClipStore.shared.markOutboundDelivered(ids: authorizedIDs)
        authorizedIDs.forEach { setStatus(id: $0, state: "delivered") }
        return true
    }

    public func acceptIncoming(metadata: [String: Any], body: Data, token: String) -> Bool {
        guard let device = ClipStore.shared.pairedDevices.first(where: { $0.securePairing == true && !$0.token.isEmpty && $0.token == token }),
              let wireID = metadata["transferId"] as? String, wireID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let kind = metadata["kind"] as? String, ["text", "image", "file"].contains(kind), body.count <= Self.maxBytes else { return false }
        let id = TransferIdentity.scoped(owner: device.id, id: wireID)
        if ClipStore.shared.seenTransferAttempt(id) { return true }
        guard let size = metadata["size"] as? NSNumber, size.int64Value == Int64(body.count),
              let expectedHash = metadata["sha256"] as? String,
              expectedHash.isEmpty || expectedHash.lowercased() == Self.sha256(body) else { return false }
        guard kind != "text" || (String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) else { return false }
        let text = kind == "text" ? String(decoding: body, as: UTF8.self) : ""
        var stored: URL?
        if kind != "text" {
            let dir = ClipStore.shared.attachmentDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = String((metadata["name"] as? String ?? "attachment").replacingOccurrences(of: "/", with: "_").prefix(120))
            let target = dir.appendingPathComponent(UUID().uuidString + "." + String(URL(fileURLWithPath: name).pathExtension.prefix(12)))
            do { try body.write(to: target, options: .atomic); stored = target } catch { return false }
        }
        let saved = ClipStore.shared.addTransferredItem(id: id, text: text, appName: metadata["app"] as? String ?? device.name, packageName: metadata["package"] as? String ?? "", timestamp: Date(timeIntervalSince1970: (metadata["timestamp"] as? Double ?? Double(Date().timeIntervalSince1970 * 1000)) / 1000), kind: kind, mimeType: metadata["mimeType"] as? String, attachmentName: metadata["name"] as? String, attachmentPath: stored?.path, direction: "received", sourceDeviceId: device.id, contentHash: Self.sha256(body))
        if !saved, let stored { try? FileManager.default.removeItem(at: stored) }
        return saved
    }

    private func add(_ record: OutboundRecord) throws { let previous = records; records.removeAll { $0.transferId == record.transferId }; records.append(record); do { try persistThrowing() } catch { records = previous; throw error }; wakeInboxWaiters(deviceID: record.deviceId) }
    private func persist() { try? persistThrowing() }
    private func persistThrowing() throws { let data = try JSONEncoder().encode(records); try PrivateAppStorage.write(data, to: fileURL) }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public enum TransferError: Error { case invalidSize, invalidDevice }
