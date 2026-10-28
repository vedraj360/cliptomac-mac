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
        return try IncomingTransferControls.shared.receiving(owner: owner, id: id) {
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
    }
    func complete(owner: String, id: String, destination: URL) throws -> (TransferManifest, URL) {
        lock.lock(); defer { lock.unlock() }
        return try IncomingTransferControls.shared.receiving(owner: owner, id: id) {
        let directory = try directory(owner, id)
        var receipt = try load(directory)
        let safe = AttachmentFilename.safeName(receipt.manifest.name, mimeType: receipt.manifest.mimeType)
        let stableName = TransferVerifier.digest(Data((owner + ":" + id).utf8)) + "-" + safe
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
    }
    func pending(owner: String) -> [(TransferManifest, Int64)] {
        lock.lock(); defer { lock.unlock() }
        let folder = root.appendingPathComponent(TransferVerifier.digest(Data(owner.utf8)))
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let receipt = try? load(child), receipt.finalPath == nil else { return nil }
            let bytes = receipt.received.keys.reduce(Int64(0)) { $0 + Int64((try? receipt.manifest.length($1)) ?? 0) }
            return (receipt.manifest, bytes)
        }
    }

    /// Called only after history and its duplicate ledger have been saved successfully.
    func retireCommitted(owner: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let folder = try directory(owner, id)
        guard FileManager.default.fileExists(atPath: folder.path), try load(folder).finalPath != nil else { return }
        try FileManager.default.removeItem(at: folder)
        let parent = folder.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    /// Recover cleanup interrupted after a durable commit; leave unfinished transfers resumable.
    func pruneCommitted(_ isCommitted: (String) -> Bool, isCancelled: (String) -> Bool = { _ in false }) {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        for owner in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard owner.lastPathComponent.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  (try? owner.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            for folder in (try? manager.contentsOfDirectory(at: owner, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
                guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let receipt = try? load(folder) else { continue }
                let scopedID = String(owner.lastPathComponent.prefix(16)) + "-" + folder.lastPathComponent
                guard (receipt.finalPath != nil && isCommitted(scopedID)) || (receipt.finalPath == nil && isCancelled(scopedID)) else { continue }
                try? manager.removeItem(at: folder)
            }
            if (try? manager.contentsOfDirectory(atPath: owner.path).isEmpty) == true { try? manager.removeItem(at: owner) }
        }
    }

    func cancel(owner: String, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let directory = try directory(owner, id)
        if let receipt = try? load(directory), receipt.finalPath != nil { return }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
