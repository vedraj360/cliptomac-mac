import Foundation

public struct FileTransferStatus: Identifiable, Equatable {
    public let id: String
    public let deviceID: String
    public let deviceName: String
    public let name: String
    public let bytesSent: Int64
    public let totalBytes: Int64
    public let state: String
    public let error: String?
    public let createdAt: Date
    public let bytesPerSecond: Double
    public let estimatedSecondsRemaining: Double?
    public let direction: String
    public init(id: String, deviceID: String, deviceName: String, name: String, bytesSent: Int64, totalBytes: Int64, state: String, error: String?, createdAt: Date, bytesPerSecond: Double = 0, estimatedSecondsRemaining: Double? = nil, direction: String = "sent") {
        self.id = id; self.deviceID = deviceID; self.deviceName = deviceName; self.name = name; self.bytesSent = bytesSent; self.totalBytes = totalBytes; self.state = state; self.error = error; self.createdAt = createdAt; self.bytesPerSecond = bytesPerSecond; self.estimatedSecondsRemaining = estimatedSecondsRemaining; self.direction = direction
    }
}
