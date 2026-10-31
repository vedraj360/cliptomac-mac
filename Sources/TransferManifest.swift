import Foundation

/// Version 2 wire format. Sizes and offsets are 64-bit; file size has no protocol cap.
struct TransferManifest: Codable, Equatable {
  static let bucketBytes = ClipToMacProtocol.HTTP.bucketBodyLimitBytes
  let protocolVersion: Int
  let transferId: String
  let size: Int64
  let bucketSize: Int
  let sha256: String
  let kind: String
  let mimeType: String
  let name: String
  let app: String
  let package: String
  let timestamp: Int64
  var bucketCount: Int { size == 0 ? 0 : Int((size - 1) / Int64(bucketSize) + 1) }
  func validate() throws {
    guard protocolVersion == ClipToMacProtocol.transferVersion,
      ClipToMacProtocol.isValidTransferIdentifier(transferId),
      size >= 0, bucketSize == Self.bucketBytes, ["file", "image"].contains(kind),
      ClipToMacProtocol.isSHA256Hex(sha256),
      name.utf8.count <= 1024, mimeType.utf8.count <= 255
    else { throw BucketError.invalid(TransferErrors.invalidManifest) }
  }
  func length(_ index: Int) throws -> Int {
    guard index >= 0, index < bucketCount else {
      throw BucketError.invalid(TransferErrors.invalidBucketIndex)
    }
    return Int(min(Int64(bucketSize), size - Int64(index) * Int64(bucketSize)))
  }
  var json: [String: Any] {
    var result: [String: Any] = [:]
    result["protocolVersion"] = protocolVersion
    result["transferId"] = transferId
    result["size"] = size
    result["bucketSize"] = bucketSize
    result["bucketCount"] = bucketCount
    result["sha256"] = sha256
    result["kind"] = kind
    result["mimeType"] = mimeType
    result["name"] = name
    result["app"] = app
    result["package"] = package
    result["timestamp"] = timestamp
    return result
  }
}

enum BucketError: LocalizedError {
  case invalid(String)
  var errorDescription: String? {
    switch self {
    case .invalid(let message): return message
    }
  }
}

/// Namespacing prevents one paired phone's retry IDs from suppressing another phone's clips.
enum TransferIdentity {
  static func scoped(owner: String, id: String) -> String {
    String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-" + id
  }
}
