import Foundation

/// Disk-backed receipt ledger. A receipt is durable only after the bucket data is synced.
final class BucketTransferStorage: @unchecked Sendable {
    static let shared = BucketTransferStorage()
    private struct Receipt: Codable {
        let manifest: TransferManifest
        var received: [Int: String] = [:]
        var finalPath: String? = nil
    }
    private let root: URL
    private let lock = NSLock()
    init(root: URL? = nil) {
        #if CLIPTOMAC_TRANSFER_TEST
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ClipToMac-buckets-\(UUID().uuidString)")
        #else
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipToMac/BucketTransfers")
        #endif
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    private func directory(_ owner: String, _ id: String) throws -> URL {
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw BucketError.invalid("Invalid transfer ID") }
        return root.appendingPathComponent(TransferVerifier.digest(Data(owner.utf8))).appendingPathComponent(id)
    }
    private func load(_ directory: URL) throws -> Receipt { try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json"))) }
    private func save(_ receipt: Receipt, _ directory: URL) throws { try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("receipt.json"), options: .atomic) }

    func start(_ manifest: TransferManifest, owner: String) throws -> [String: Any] {
        try manifest.validate()
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(owner, manifest.transferId)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipt.json").path) {
            let receipt = try load(directory)
            guard receipt.manifest == manifest else { throw BucketError.invalid("Transfer ID already belongs to different content") }
            return ["received": receipt.received.keys.sorted(), "complete": receipt.finalPath != nil]
        }
        guard try TransferVerifier.availableBytes(at: root) >= manifest.size else { throw BucketError.invalid("Not enough storage on Mac") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let part = directory.appendingPathComponent("payload.part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(manifest.size)); try handle.synchronize()
        try save(Receipt(manifest: manifest), directory)
        return ["received": [Int](), "complete": false]
    }
    @discardableResult func put(owner: String, id: String, index: Int, bytes: Data, checksum: String) throws -> (TransferManifest, Int64) {
        guard checksum == TransferVerifier.digest(bytes) else { throw BucketError.invalid("Bucket checksum mismatch") }
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(owner, id)
        var receipt = try load(directory)
        guard try receipt.manifest.length(index) == bytes.count else { throw BucketError.invalid("Incorrect bucket length") }
        if let previous = receipt.received[index] {
            guard previous == checksum else { throw BucketError.invalid("Conflicting bucket retry") }
            return (receipt.manifest, receipt.received.keys.reduce(0) { $0 + Int64((try? receipt.manifest.length($1)) ?? 0) })
        }
        guard receipt.finalPath == nil else { throw BucketError.invalid("Transfer already finalized") }
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("payload.part"))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index) * UInt64(receipt.manifest.bucketSize))
        try handle.write(contentsOf: bytes); try handle.synchronize()
        receipt.received[index] = checksum
        try save(receipt, directory)
        return (receipt.manifest, receipt.received.keys.reduce(0) { $0 + Int64((try? receipt.manifest.length($1)) ?? 0) })
    }
    func complete(owner: String, id: String, destination: URL) throws -> (TransferManifest, URL) {
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(owner, id)
        var receipt = try load(directory)
        let safe = String(receipt.manifest.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_").unicodeScalars.prefix(30).map(Character.init))
        let stableName = TransferVerifier.digest(Data((owner + ":" + id).utf8)) + "-" + (safe.isEmpty ? "attachment" : safe)
        let final = destination.appendingPathComponent(stableName)
        let part = directory.appendingPathComponent("payload.part")
        if receipt.finalPath == nil, !FileManager.default.fileExists(atPath: part.path), FileManager.default.fileExists(atPath: final.path),
           try TransferVerifier.digest(file: final) == receipt.manifest.sha256 {
            receipt.finalPath = final.path; try save(receipt, directory)
        }
        if let final = receipt.finalPath {
            guard FileManager.default.fileExists(atPath: final) else { throw BucketError.invalid("Completed file is no longer available") }
            return (receipt.manifest, URL(fileURLWithPath: final))
        }
        guard receipt.received.count == receipt.manifest.bucketCount else { throw BucketError.invalid("Missing buckets") }
        guard try TransferVerifier.digest(file: part) == receipt.manifest.sha256 else {
            // Force a clean retry rather than trapping a corrupted transfer forever.
            receipt.received = [:]; try save(receipt, directory)
            throw BucketError.invalid("Complete file checksum mismatch; retry transfer")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: part, to: final)
        receipt.finalPath = final.path
        do { try save(receipt, directory) } catch { try? FileManager.default.moveItem(at: final, to: part); throw error }
        return (receipt.manifest, final)
    }
    func cancel(owner: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(owner, id)
        if let receipt = try? load(directory), receipt.finalPath != nil { return }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
