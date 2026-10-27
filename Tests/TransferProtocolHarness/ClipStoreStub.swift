import Foundation

public enum ClipKind: String { case text, image, file }
public struct PairedDevice: Identifiable, Codable, Equatable {
    public let id: String; public let name: String; public let token: String; public let pairedAt: Date
    public init(id: String, name: String, token: String, pairedAt: Date = Date()) { self.id=id; self.name=name; self.token=token; self.pairedAt=pairedAt }
}
@MainActor public final class ClipStore {
    public static let shared = ClipStore()
    public var pairedDevices: [PairedDevice] = []
    public var hasPairedDevices: Bool { !pairedDevices.isEmpty }
    public var pairedDeviceName: String { pairedDevices.map(\.name).joined(separator: ", ") }
    public let attachmentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipToMac-transfer-test-attachments-\(UUID().uuidString)")
    public init() { try? FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true) }
    @discardableResult public func saveTrustedDevice(id: String, name: String, token: String) -> Bool { pairedDevices.removeAll { $0.id == id }; pairedDevices.append(PairedDevice(id:id,name:name,token:token)); return true }
    public func migrateDeviceIdentity(token: String, id: String) -> Bool { guard let i = pairedDevices.firstIndex(where: { $0.token == token }), id.hasPrefix("android-") else { return false }; let old = pairedDevices[i]; pairedDevices[i] = PairedDevice(id: id, name: old.name, token: token, pairedAt: old.pairedAt); return true }
    @discardableResult public func unpairDevice(id: String? = nil) -> Bool { if let id { pairedDevices.removeAll { $0.id == id } } else { pairedDevices=[] }; return true }
    public func seenTransferAttempt(_ id: String) -> Bool { seen.contains(id) }
    public func addTransferredItem(id: String, text: String, appName: String, packageName: String, timestamp: Date, kind: String, mimeType: String? = nil, attachmentName: String? = nil, attachmentPath: String? = nil, direction: String = "received", sourceDeviceId: String? = nil, contentHash: String? = nil) -> Bool { guard !seen.contains(id) else{return false}; seen.insert(id); received[id] = (text, attachmentPath); return true }
    public func markOutboundDelivered(ids: [String]) { delivered.formUnion(ids) }
    public func recordOutbound(text: String, fileURL: URL? = nil, to device: PairedDevice, transferID: String, kind: ClipKind? = nil, mimeType: String? = nil, contentHash: String? = nil, attachmentName: String? = nil) -> Bool { recorded.insert(transferID); return true }
    public func addClips(items: [(text:String, appName:String, packageName:String, timestamp:Date)]) {}
    var seen = Set<String>(); var delivered = Set<String>(); var recorded = Set<String>(); var received: [String:(String,String?)] = [:]
}
public enum PairingDialog { public static func request(deviceName: String, code: String) -> Bool { true } }
