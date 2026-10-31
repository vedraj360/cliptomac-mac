import Foundation

private typealias HTTPContract = ClipToMacProtocol.HTTP

extension HTTPServer {
  /// Authenticate on the main actor, perform disk/checksum work off the UI thread.
  @MainActor func routeBuckets(_ fd: Int32, _ req: Request, device: PairedDevice) -> Bool {
    guard req.path.hasPrefix(HTTPContract.Path.bucketsPrefix) else { return false }
    let pieces = req.path.split(separator: "/").map(String.init)
    let owner = device.id
    if req.method == HTTPContract.Method.get, pieces.count == 3,
      pieces[2] == HTTPContract.Path.bucketControlSegment
    {
      guard ClipToMacProtocol.isValidTransferIdentifier(pieces[1]) else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidTransferIdentifier])
        return true
      }
      respond(
        fd, HTTPContract.StatusCode.ok,
        ["state": IncomingTransferControls.shared.state(owner: owner, id: pieces[1])])
      return true
    }
    if req.method == HTTPContract.Method.post, req.path == HTTPContract.Path.bucketStart {
      guard let manifest = try? JSONDecoder().decode(TransferManifest.self, from: req.body) else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidManifest])
        return true
      }
      do { try manifest.validate() } catch {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidManifest])
        return true
      }
      if ClipStore.shared.seenTransferAttempt(
        TransferIdentity.scoped(owner: owner, id: manifest.transferId))
      {
        respond(fd, HTTPContract.StatusCode.ok, ["received": [Int](), "complete": true])
        return true
      }
      Task.detached {
        do {
          try IncomingTransferControls.shared.receiving(owner: owner, id: manifest.transferId) {}
          var receipt = try BucketTransferStorage.shared.start(manifest, owner: owner)
          // Only a committed history/ledger entry is a completed delivery.
          receipt["complete"] = false
          let indices = receipt["received"] as? [Int] ?? []
          let bytes = indices.reduce(Int64(0)) { $0 + Int64((try? manifest.length($1)) ?? 0) }
          await MainActor.run {
            MacTransferService.shared.updateIncoming(manifest, device: device, bytes: bytes)
            IncomingByteProgress.shared.register(
              owner: owner, token: device.token, manifest: manifest, received: indices
            ) { count in
              Task { @MainActor in
                guard
                  ClipStore.shared.pairedDevices.contains(where: {
                    $0.id == owner && $0.token == device.token && $0.securePairing == true
                  })
                else { return }
                MacTransferService.shared.updateIncoming(manifest, device: device, bytes: count)
              }
            }
          }
          self.respond(fd, HTTPContract.StatusCode.ok, receipt)
        } catch let error as IncomingTransferControls.ControlError {
          self.respond(
            fd, error.status, [HTTPContract.ResponseKey.error: error.localizedDescription])
        } catch {
          self.respond(
            fd, HTTPContract.StatusCode.badRequest,
            [HTTPContract.ResponseKey.error: error.localizedDescription])
        }
      }
    } else if req.method == HTTPContract.Method.put, pieces.count == 3, let index = Int(pieces[2]) {
      let checksum = req.headers[HTTPContract.Header.bucketChecksum] ?? ""
      Task.detached {
        do {
          let (manifest, bytes) = try BucketTransferStorage.shared.put(
            owner: owner, id: pieces[1], index: index, bytes: req.body, checksum: checksum)
          IncomingByteProgress.shared.confirmed(token: device.token, id: pieces[1], index: index)
          await MainActor.run {
            MacTransferService.shared.updateIncoming(manifest, device: device, bytes: bytes)
          }
          self.respond(
            fd, HTTPContract.StatusCode.ok,
            [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok])
        } catch let error as IncomingTransferControls.ControlError {
          self.respond(
            fd, error.status, [HTTPContract.ResponseKey.error: error.localizedDescription])
        } catch {
          self.respond(
            fd, HTTPContract.StatusCode.badRequest,
            [HTTPContract.ResponseKey.error: error.localizedDescription])
        }
      }
    } else if req.method == HTTPContract.Method.post, pieces.count == 3,
      pieces[2] == HTTPContract.Path.bucketCompleteSegment
    {
      let committedID =
        String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-" + pieces[1]
      if ClipStore.shared.seenTransferAttempt(committedID) {
        respond(
          fd, HTTPContract.StatusCode.ok,
          [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.complete])
        return true
      }
      let destination = ClipStore.shared.attachmentDirectory
      Task.detached {
        do {
          await MainActor.run {
            MacTransferService.shared.incomingState(
              owner: owner, transferID: pieces[1], state: "verifying")
          }
          let (manifest, file) = try BucketTransferStorage.shared.complete(
            owner: owner, id: pieces[1], destination: destination)
          let saved = await MainActor.run { () -> Bool in
            guard
              ClipStore.shared.pairedDevices.contains(where: {
                $0.securePairing == true && $0.id == owner && $0.token == device.token
              })
            else { return false }
            let scopedID =
              String(TransferVerifier.digest(Data(owner.utf8)).prefix(16)) + "-"
              + manifest.transferId
            if ClipStore.shared.seenTransferAttempt(scopedID) { return true }
            return ClipStore.shared.addTransferredItem(
              id: scopedID, text: "", appName: manifest.app, packageName: manifest.package,
              timestamp: Date(timeIntervalSince1970: Double(manifest.timestamp) / 1000),
              kind: manifest.kind, mimeType: manifest.mimeType, attachmentName: manifest.name,
              attachmentPath: file.path, direction: "received", sourceDeviceId: owner,
              contentHash: manifest.sha256)
          }
          if saved {
            do {
              try BucketTransferStorage.shared.retireCommitted(owner: owner, id: pieces[1])
            } catch { print("Completed transfer cleanup will retry at launch") }
          }
          await MainActor.run {
            MacTransferService.shared.incomingState(
              owner: owner, transferID: pieces[1], state: saved ? "complete" : "failed")
          }
          self.respond(
            fd, saved ? HTTPContract.StatusCode.ok : HTTPContract.StatusCode.internalServerError,
            [HTTPContract.ResponseKey.status: saved ? "complete" : "Could not save received file"])
        } catch let error as IncomingTransferControls.ControlError {
          self.respond(
            fd, error.status, [HTTPContract.ResponseKey.error: error.localizedDescription])
        } catch {
          await MainActor.run {
            MacTransferService.shared.incomingState(
              owner: owner, transferID: pieces[1], state: "failed",
              error: error.localizedDescription)
          }
          self.respond(
            fd, HTTPContract.StatusCode.badRequest,
            [HTTPContract.ResponseKey.error: error.localizedDescription])
        }
      }
    } else if req.method == HTTPContract.Method.delete, pieces.count == 2 {
      Task.detached {
        do {
          if IncomingTransferControls.shared.state(owner: owner, id: pieces[1]) != "cancelled" {
            try IncomingTransferControls.shared.set(owner: owner, id: pieces[1], state: "cancelled")
          }
          try BucketTransferStorage.shared.cancel(owner: owner, id: pieces[1])
          await MainActor.run {
            MacTransferService.shared.incomingState(
              owner: owner, transferID: pieces[1], state: "cancelled")
          }
          self.respond(
            fd, HTTPContract.StatusCode.ok,
            [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.cancelled])
        } catch let error as IncomingTransferControls.ControlError {
          self.respond(
            fd, error.status, [HTTPContract.ResponseKey.error: error.localizedDescription])
        } catch {
          self.respond(
            fd, HTTPContract.StatusCode.badRequest,
            [HTTPContract.ResponseKey.error: error.localizedDescription])
        }
      }
    } else if req.method == HTTPContract.Method.get, pieces.count == 4,
      pieces[1] == HTTPContract.Path.bucketDownloadSegment,
      let manifest = MacTransferService.shared.bucketManifest(id: pieces[2], token: device.token),
      let file = MacTransferService.shared.download(transferID: pieces[2], token: device.token)
    {
      if pieces[3] == HTTPContract.Path.bucketManifestSegment {
        respond(fd, HTTPContract.StatusCode.ok, manifest.json)
      } else if let index = Int(pieces[3]) {
        Task.detached {
          do {
            let expected = try manifest.length(index)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(index) * UInt64(manifest.bucketSize))
            guard let bytes = try handle.read(upToCount: expected), bytes.count == expected else {
              throw BucketError.invalid(TransferErrors.sourceFileUnavailable)
            }
            let hash = TransferVerifier.digest(bytes)
            self.respond(
              fd, HTTPContract.StatusCode.ok, raw: bytes, contentType: "application/octet-stream",
              extraHeaders: ["X-Bucket-SHA256": hash])
            await MainActor.run {
              MacTransferService.shared.updateBucketProgress(
                id: pieces[2], index: index, manifest: manifest)
            }
          } catch let error as IncomingTransferControls.ControlError {
            self.respond(
              fd, error.status, [HTTPContract.ResponseKey.error: error.localizedDescription])
          } catch {
            self.respond(
              fd, HTTPContract.StatusCode.badRequest,
              [HTTPContract.ResponseKey.error: error.localizedDescription])
          }
        }
      } else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidBucketIndex])
      }
    } else {
      respond(
        fd, HTTPContract.StatusCode.notFound,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.bucketTransferUnavailable])
    }
    return true
  }
}
