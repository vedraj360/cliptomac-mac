import Foundation

extension HTTPServer {
    /// Authenticate on the main actor, perform disk/checksum work off the UI thread.
    @MainActor func routeBuckets(_ fd: Int32, _ req: Request, device: PairedDevice) -> Bool {
        guard req.path.hasPrefix("/buckets/") else { return false }
        let pieces = req.path.split(separator: "/").map(String.init)
        let owner = device.id
        if req.method == "POST", req.path == "/buckets/start" {
            guard let manifest = try? JSONDecoder().decode(TransferManifest.self, from: req.body) else { respond(fd, 400, ["error": "Invalid manifest"]); return true }
            Task.detached {
                do {
                    let receipt = try BucketTransferStorage.shared.start(manifest, owner: owner)
                    let indices = receipt["received"] as? [Int] ?? []
                    let bytes = indices.reduce(Int64(0)) { $0 + Int64((try? manifest.length($1)) ?? 0) }
                    await MainActor.run { MacTransferService.shared.updateIncoming(manifest, device: device, bytes: bytes) }
                    self.respond(fd, 200, receipt)
                }
                catch { self.respond(fd, 400, ["error": error.localizedDescription]) }
            }
        } else if req.method == "PUT", pieces.count == 3, let index = Int(pieces[2]) {
            let checksum = req.headers["x-bucket-sha256"] ?? ""
            Task.detached {
                do {
                    let (manifest, bytes) = try BucketTransferStorage.shared.put(owner: owner, id: pieces[1], index: index, bytes: req.body, checksum: checksum)
                    await MainActor.run { MacTransferService.shared.updateIncoming(manifest, device: device, bytes: bytes) }
                    self.respond(fd, 200, ["status": "ok"])
                }
                catch { self.respond(fd, 400, ["error": error.localizedDescription]) }
            }
        } else if req.method == "POST", pieces.count == 3, pieces[2] == "complete" {
            let committedID = String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-" + pieces[1]
            if ClipStore.shared.seenTransferAttempt(committedID) { respond(fd, 200, ["status": "complete"]); return true }
            let destination = ClipStore.shared.attachmentDirectory
            Task.detached {
                do {
                    await MainActor.run { MacTransferService.shared.incomingState(owner: owner, transferID: pieces[1], state: "verifying") }
                    let (manifest, file) = try BucketTransferStorage.shared.complete(owner: owner, id: pieces[1], destination: destination)
                    let saved = await MainActor.run { () -> Bool in
                        guard ClipStore.shared.pairedDevices.contains(where: { $0.securePairing == true && $0.id == owner && $0.token == device.token }) else { return false }
                        let scopedID = String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-" + manifest.transferId
                        if ClipStore.shared.seenTransferAttempt(scopedID) { return true }
                        return ClipStore.shared.addTransferredItem(id: scopedID, text: "", appName: manifest.app, packageName: manifest.package, timestamp: Date(timeIntervalSince1970: Double(manifest.timestamp) / 1000), kind: manifest.kind, mimeType: manifest.mimeType, attachmentName: manifest.name, attachmentPath: file.path, direction: "received", sourceDeviceId: owner, contentHash: manifest.sha256)
                    }
                    await MainActor.run { MacTransferService.shared.incomingState(owner: owner, transferID: pieces[1], state: saved ? "complete" : "failed") }
                    self.respond(fd, saved ? 200 : 500, ["status": saved ? "complete" : "Could not save received file"])
                } catch {
                    await MainActor.run { MacTransferService.shared.incomingState(owner: owner, transferID: pieces[1], state: "failed", error: error.localizedDescription) }
                    self.respond(fd, 400, ["error": error.localizedDescription])
                }
            }
        } else if req.method == "DELETE", pieces.count == 2 {
            Task.detached {
                do { try BucketTransferStorage.shared.cancel(owner: owner, id: pieces[1]); await MainActor.run { MacTransferService.shared.incomingState(owner: owner, transferID: pieces[1], state: "cancelled") }; self.respond(fd, 200, ["status": "cancelled"]) }
                catch { self.respond(fd, 400, ["error": error.localizedDescription]) }
            }
        } else if req.method == "GET", pieces.count == 4, pieces[1] == "download",
                  let manifest = MacTransferService.shared.bucketManifest(id: pieces[2], token: device.token),
                  let file = MacTransferService.shared.download(transferID: pieces[2], token: device.token) {
            if pieces[3] == "manifest" { respond(fd, 200, manifest.json) }
            else if let index = Int(pieces[3]) {
                Task.detached {
                    do {
                        let expected = try manifest.length(index)
                        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                        try handle.seek(toOffset: UInt64(index) * UInt64(manifest.bucketSize))
                        guard let bytes = try handle.read(upToCount: expected), bytes.count == expected else { throw BucketError.invalid("Source file changed or is unavailable") }
                        let hash = TransferVerifier.digest(bytes)
                        self.respond(fd, 200, raw: bytes, contentType: "application/octet-stream", extraHeaders: ["X-Bucket-SHA256": hash])
                        await MainActor.run { MacTransferService.shared.updateBucketProgress(id: pieces[2], index: index, manifest: manifest) }
                    } catch { self.respond(fd, 400, ["error": error.localizedDescription]) }
                }
            } else { respond(fd, 400, ["error": "Invalid bucket index"]) }
        } else { respond(fd, 404, ["error": "Bucket transfer unavailable"]) }
        return true
    }
}
