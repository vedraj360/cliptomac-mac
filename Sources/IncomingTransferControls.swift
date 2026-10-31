import Foundation

/// Receiver decisions survive retries/restarts and are scoped to the authenticated phone.
final class IncomingTransferControls: @unchecked Sendable {
  static let shared = IncomingTransferControls()
  private let lock = NSRecursiveLock()
  private let file: URL
  private var states: [String: String]
  init(directory: URL? = nil) {
    #if CLIPTOMAC_TRANSFER_TEST
      let root =
        directory
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "ClipToMac-controls-test-\(UUID().uuidString)")
    #else
      let root =
        directory
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipToMac")
    #endif
    file = root.appendingPathComponent("incoming-transfer-controls.json")
    states = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
  }
  func state(owner: String, id: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    return states[TransferIdentity.scoped(owner: owner, id: id)] ?? "receiving"
  }
  func isCancelled(scopedID: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return states[scopedID] == "cancelled"
  }
  func set(owner: String, id: String, state: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let key = TransferIdentity.scoped(owner: owner, id: id)
    guard states[key] != "cancelled" else { throw ControlError.cancelled }
    var updated = states
    if state == "receiving" { updated.removeValue(forKey: key) } else { updated[key] = state }
    try PrivateAppStorage.prepare(file.deletingLastPathComponent())
    try PrivateAppStorage.write(JSONEncoder().encode(updated), to: file)
    states = updated
  }
  func receiving<T>(owner: String, id: String, _ operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    switch state(owner: owner, id: id) {
    case "paused": throw ControlError.paused
    case "cancelled": throw ControlError.cancelled
    default: return try operation()
    }
  }
  enum ControlError: LocalizedError {
    case paused, cancelled
    var errorDescription: String? {
      self == .paused ? TransferErrors.transferPaused : TransferErrors.transferCancelled
    }
    var status: Int { self == .paused ? 423 : 410 }
  }
}
