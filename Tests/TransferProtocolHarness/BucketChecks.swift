import Foundation

extension Harness {
    @MainActor static func bucketChecks() async throws {
        let payload = Data(repeating: 0x5A, count: TransferManifest.bucketBytes + 321)
        let manifest = TransferManifest(protocolVersion: 2, transferId: "bucket-fixture", size: Int64(payload.count), bucketSize: TransferManifest.bucketBytes, sha256: TransferVerifier.digest(payload), kind: "file", mimeType: "application/octet-stream", name: "fixture.bin", app: "Test", package: "test", timestamp: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bucket-storage-check-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("finished")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = BucketTransferStorage(root: root)
        _ = try storage.start(manifest, owner: "a")
        let first = payload.prefix(manifest.bucketSize)
        try storage.put(owner: "a", id: manifest.transferId, index: 0, bytes: Data(first), checksum: TransferVerifier.digest(Data(first)))
        let reloaded = BucketTransferStorage(root: root)
        let receipt = try reloaded.start(manifest, owner: "a")
        precondition(receipt["received"] as? [Int] == [0], "bucket receipt did not survive restart")
        try reloaded.put(owner: "a", id: manifest.transferId, index: 0, bytes: Data(first), checksum: TransferVerifier.digest(Data(first)))
        do { try reloaded.put(owner: "a", id: manifest.transferId, index: 1, bytes: Data([1]), checksum: "bad"); fatalError("bad checksum accepted") } catch {}
        do { _ = try reloaded.complete(owner: "a", id: manifest.transferId, destination: destination); fatalError("incomplete transfer finalized") } catch {}
        do { try reloaded.put(owner: "b", id: manifest.transferId, index: 0, bytes: Data(first), checksum: TransferVerifier.digest(Data(first))); fatalError("receipt leaked across owners") } catch {}
        let last = Data(payload.suffix(321))
        try reloaded.put(owner: "a", id: manifest.transferId, index: 1, bytes: last, checksum: TransferVerifier.digest(last))
        let (_, file) = try reloaded.complete(owner: "a", id: manifest.transferId, destination: destination)
        let verifiedHash = try TransferVerifier.digest(file: file)
        precondition(verifiedHash == manifest.sha256)
        let (_, retriedFile) = try BucketTransferStorage(root: root).complete(owner: "a", id: manifest.transferId, destination: destination)
        precondition(file == retriedFile, "retry created a second completed file")
        for name in ["Screenshot_2026-10-27-18-01-49-38_8d0656beae16965edc8a4b879c1ffbb0.jpg", String(repeating: "界", count: 200) + ".png", "../../escape.mp4"] {
            let safe = AttachmentFilename.safeName(name, mimeType: "image/jpeg")
            precondition((safe as NSString).pathExtension == (name as NSString).pathExtension, "Filename lost its extension")
            precondition(safe.utf8.count <= 180 && !safe.contains("/"), "Unsafe or oversized filename")
        }
        precondition(["jpg", "jpeg"].contains((AttachmentFilename.safeName("photo", mimeType: "image/jpeg") as NSString).pathExtension))
        try reloaded.retireCommitted(owner: "a", id: manifest.transferId)
        precondition(FileManager.default.fileExists(atPath: file.path), "Cleanup removed the saved attachment")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(TransferVerifier.digest(Data("a".utf8))).appendingPathComponent(manifest.transferId).path), "Cleanup left a completed receipt directory")
        let sparse = TransferManifest(protocolVersion: 2, transferId: "offset-over-5gib", size: 5 * 1024 * 1024 * 1024 + 123, bucketSize: TransferManifest.bucketBytes, sha256: String(repeating: "0", count: 64), kind: "file", mimeType: "application/octet-stream", name: "large.bin", app: "Test", package: "test", timestamp: 1)
        _ = try storage.start(sparse, owner: "a")
        let tail = Data(repeating: 77, count: 123)
        try storage.put(owner: "a", id: sparse.transferId, index: sparse.bucketCount - 1, bytes: tail, checksum: TransferVerifier.digest(tail))
        let largeReceipt = try storage.start(sparse, owner: "a")
        precondition(largeReceipt["received"] as? [Int] == [sparse.bucketCount - 1], "64-bit bucket offset failed")
        try storage.cancel(owner: "a", id: sparse.transferId)

        @Sendable func request(_ method: String, _ path: String, _ data: Data = Data(), token: String = "token-a", checksum: String? = nil, fragment: Int = Int.max) async throws -> Data {
            let extra = checksum.map { "X-Bucket-SHA256: \($0)\r\n" } ?? ""
            let head = Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: \(token)\r\n\(extra)Content-Length: \(data.count)\r\n\r\n".utf8)
            return try await requestAsync(head + data, fragmentSize: fragment)
        }
        let meta = try JSONEncoder().encode(manifest)
        let created = try await request("POST", "/buckets/start", meta)
        precondition(status(created) == 200)
        let a = Task { try await request("PUT", "/buckets/bucket-fixture/0", Data(first), checksum: TransferVerifier.digest(Data(first)), fragment: 1024) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let progressID = TransferIdentity.scoped(owner: "test-a", id: manifest.transferId)
        let liveBytes = MacTransferService.shared.incomingItems.first(where: { $0.id == progressID })?.bytesSent ?? 0
        precondition(liveBytes > 0 && liveBytes < Int64(manifest.bucketSize), "No live receiving progress before bucket completion")
        async let b = request("PUT", "/buckets/bucket-fixture/1", last, checksum: TransferVerifier.digest(last))
        let results = try await [a.value, b]
        precondition(results.allSatisfy { status($0) == 200 }, "parallel bucket upload failed")
        let leaked = try await request("PUT", "/buckets/bucket-fixture/1", last, token: "token-b", checksum: TransferVerifier.digest(last))
        precondition(status(leaked) == 400, "cross-device bucket accepted")
        let complete = try await request("POST", "/buckets/bucket-fixture/complete")
        precondition(status(complete) == 200, "bucket commit failed")
        let repeated = try await request("POST", "/buckets/bucket-fixture/complete")
        precondition(status(repeated) == 200, "commit retry was not idempotent")
        let replayStart = try await request("POST", "/buckets/start", meta)
        precondition(status(replayStart) == 200)
        let replayBody = try JSONSerialization.jsonObject(with: Data(replayStart.suffix(from: replayStart.range(of: Data("\r\n\r\n".utf8))!.upperBound))) as! [String: Any]
        precondition(replayBody["complete"] as? Bool == true, "Cleaned transfer was not recognized on retry")
        print("PASS filenames preserve extensions; committed receipt cleanup keeps attachments; start retry stays complete")
        print("PASS buckets: parallel HTTP upload, checksums, restart resume, duplicate receipts/commit, device isolation, missing-bucket rejection, >5 GiB sparse offset")
    }
}
