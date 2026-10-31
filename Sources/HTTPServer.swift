import AppKit
import CryptoKit
import Foundation
import Network
import Security

private typealias HTTPContract = ClipToMacProtocol.HTTP

public final class HTTPServer {
  public static let shared = HTTPServer()
  private var tlsListener: NWListener?
  private var tlsBridges: [UUID: TLSSocketBridge] = [:]
  private var serverFd: Int32 = -1
  private var isRunning = false
  private let queue = DispatchQueue(label: "com.vdx.cliptomac.server", qos: .userInitiated)
  private let connectionSlots = DispatchSemaphore(value: HTTPContract.maximumConcurrentConnections)
  @MainActor private static let pairingPolicy = PairingRequestPolicy()
  @MainActor private var inboxWaiters = 0
  @MainActor private var notificationReplyWaiters = 0
  private let maxBody = HTTPContract.maximumBodyBytes

  public func start(port: Int = 5678) {
    #if CLIPTOMAC_TRANSFER_TEST
      startTestHTTP(port: port)
    #else
      do { try startTLS(port: port) } catch {
        Task { @MainActor in SecurePairing.shared.error = HTTPServerErrors.tlsServerStartFailed }
      }
    #endif
  }

  func startTLS(port: Int, identity: TLSIdentity = .shared) throws {
    let credentials = try identity.load()
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    guard let localIdentity = sec_identity_create(credentials.identity),
      let rawPort = UInt16(exactly: port), rawPort > 0,
      let endpoint = NWEndpoint.Port(rawValue: rawPort)
    else { throw TLSIdentity.TLSError.identity }
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: endpoint)
    tlsListener = listener
    listener.stateUpdateHandler = { state in
      if case .failed = state {
        Task { @MainActor in SecurePairing.shared.error = HTTPServerErrors.tlsListenerFailed }
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self, self.connectionSlots.wait(timeout: .now()) == .success else {
        connection.cancel()
        return
      }
      var pair: [Int32] = [-1, -1]
      guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
        self.connectionSlots.signal()
        connection.cancel()
        return
      }
      let id = UUID()
      let bridge = TLSSocketBridge(connection: connection, fd: pair[1]) { [weak self] in
        self?.queue.async { self?.tlsBridges.removeValue(forKey: id) }
      }
      self.tlsBridges[id] = bridge
      bridge.start()
      let parserFD = pair[0]
      DispatchQueue.global(qos: .userInitiated).async { self.handleClient(parserFD) }
    }
    listener.start(queue: queue)
  }

  #if CLIPTOMAC_TRANSFER_TEST
    private func startTestHTTP(port: Int) {
      guard !isRunning else { return }
      queue.async { [weak self] in
        guard let self else { return }
        self.serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard self.serverFd >= 0 else { return }
        var opt: Int32 = 1
        setsockopt(
          self.serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &addr) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(self.serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
        guard bound == 0, listen(self.serverFd, HTTPContract.testListenerBacklog) == 0 else {
          close(self.serverFd)
          self.serverFd = -1
          return
        }
        self.isRunning = true
        while self.isRunning {
          self.connectionSlots.wait()
          let fd = accept(self.serverFd, nil, nil)
          guard fd >= 0 else {
            self.connectionSlots.signal()
            continue
          }
          DispatchQueue.global(qos: .userInitiated).async { self.handleClient(fd) }
        }
      }
    }

  #endif

  public func stop() {
    queue.async {
      self.tlsListener?.cancel()
      self.tlsListener = nil
      let bridges = Array(self.tlsBridges.values)
      for bridge in bridges {
        bridge.stop()
      }
      self.tlsBridges.removeAll()
    }
    isRunning = false
    if serverFd >= 0 {
      close(serverFd)
      serverFd = -1
    }
  }

  struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  private func handleClient(_ fd: Int32) {
    var timeout = timeval(tv_sec: HTTPContract.clientSocketTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    #if !os(Linux)
      var noSigPipe: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    #endif
    guard let req = readRequest(fd) else {
      respond(
        fd, HTTPContract.StatusCode.badRequest,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidRequest])
      return
    }
    Task { @MainActor in self.route(fd, req) }
  }

  private func readRequest(_ fd: Int32) -> Request? {
    let deadline = ProcessInfo.processInfo.systemUptime + HTTPContract.requestDeadlineSeconds
    var data = Data()
    let delimiter = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    var buffer = [UInt8](repeating: 0, count: HTTPContract.maximumHeaderBytes)
    while headerEnd == nil {
      guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
      let n = recv(fd, &buffer, buffer.count, 0)
      guard n > 0 else { return nil }
      data.append(contentsOf: buffer.prefix(n))
      headerEnd = data.range(of: delimiter)
      if headerEnd == nil && data.count > HTTPContract.maximumHeaderBytes { return nil }
      if let found = headerEnd, found.lowerBound > HTTPContract.maximumHeaderBytes { return nil }
    }
    guard let split = headerEnd,
      let headerText = String(data: data[..<split.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { return nil }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty, headers[key] == nil else { return nil }
      headers[key] = value
    }
    // Chunked framing is intentionally unsupported.
    if headers[HTTPContract.Header.transferEncoding] != nil { return nil }
    let length = Int(headers[HTTPContract.Header.contentLength] ?? "0")
    let path = String(parts[1]).components(separatedBy: "?")[0]
    let bodyLimit = HTTPContract.bodyLimit(for: path)
    guard let length, length >= 0, length <= bodyLimit else { return nil }
    let bodyStart = split.upperBound
    let live =
      parts[0] == HTTPContract.Method.put && headers[HTTPContract.Header.origin] == nil
        && headers[HTTPContract.Header.fetchSite] == nil
      ? IncomingByteProgress.shared.reader(
        token: headers[HTTPContract.Header.authenticationToken] ?? "", path: path, length: length)
      : nil
    live?(min(length, data.count - bodyStart))
    while data.count - bodyStart < length {
      guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
      let n = recv(fd, &buffer, min(buffer.count, length - (data.count - bodyStart)), 0)
      guard n > 0 else { return nil }
      data.append(contentsOf: buffer.prefix(n))
      live?(min(length, data.count - bodyStart))
      if data.count - bodyStart > maxBody { return nil }
    }
    return Request(
      method: String(parts[0]), path: String(parts[1]).components(separatedBy: "?")[0],
      headers: headers, body: Data(data[bodyStart..<(bodyStart + length)]))
  }

  @MainActor private func route(_ fd: Int32, _ req: Request) {
    let token = req.headers[HTTPContract.Header.authenticationToken] ?? ""
    // Browser scripts are not API clients. Reject origins even when the token is valid.
    guard req.headers[HTTPContract.Header.origin] == nil,
      req.headers[HTTPContract.Header.fetchSite] == nil
    else {
      respond(
        fd, HTTPContract.StatusCode.forbidden,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.browserRequestsForbidden])
      return
    }
    if req.method == HTTPContract.Method.options {
      respond(
        fd, HTTPContract.StatusCode.forbidden,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.browserRequestsForbidden])
      return
    }
    if req.method == HTTPContract.Method.get
      && (req.path == HTTPContract.Path.ping || req.path == HTTPContract.Path.root)
    {
      let store = ClipStore.shared
      if !token.isEmpty {
        guard let device = validDevice(token) else {
          respond(
            fd, HTTPContract.StatusCode.unauthorized,
            [HTTPContract.ResponseKey.error: HTTPServerErrors.securePairingRequired])
          return
        }
        store.markDeviceSeen(id: device.id)
      }
      respond(
        fd, HTTPContract.StatusCode.ok,
        [
          HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok,
          "service": ClipToMacProtocol.serviceName,
          "device": Host.current().localizedName ?? "MacBook",
          "isPaired": store.hasPairedDevices,
          "transferProtocol": ClipToMacProtocol.transferVersion,
          "securityProtocol": ClipToMacProtocol.securePairingVersion,
        ])
      return
    }
    if req.method == HTTPContract.Method.post && req.path == HTTPContract.Path.pairRequest {
      guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidJSON])
        return
      }
      guard let deviceId = obj["deviceId"] as? String,
        let deviceName = obj["deviceName"] as? String,
        let code = obj["code"] as? String,
        PairingRequestPolicy.valid(id: deviceId, name: deviceName, code: code)
      else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidPairingDetails])
        return
      }
      guard obj["protocolVersion"] as? Int == ClipToMacProtocol.securePairingVersion,
        let enrollmentNonce = obj["nonce"] as? String,
        SecurePairing.shared.consume(enrollmentNonce)
      else {
        respond(
          fd, HTTPContract.StatusCode.forbidden,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.freshPairingQRRequired])
        return
      }
      guard Self.pairingPolicy.begin() else {
        respond(
          fd, HTTPContract.StatusCode.tooManyRequests,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.pairingRateLimited])
        return
      }
      defer { Self.pairingPolicy.finish() }
      guard let newToken = try? PairingRequestPolicy.token() else {
        respond(
          fd, HTTPContract.StatusCode.internalServerError,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.credentialGenerationFailed])
        return
      }
      if PairingDialog.request(deviceName: deviceName, code: code) {
        guard
          ClipStore.shared.saveTrustedDevice(
            id: deviceId, name: deviceName, token: newToken, securePairing: true)
        else {
          respond(
            fd, HTTPContract.StatusCode.internalServerError,
            [HTTPContract.ResponseKey.error: HTTPServerErrors.pairingPersistenceFailed])
          return
        }
        ClipStore.shared.markDeviceSeen(id: deviceId)
        respond(
          fd, HTTPContract.StatusCode.ok,
          [
            HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok,
            "token": newToken,
            "securityProtocol": ClipToMacProtocol.securePairingVersion,
            "macName": Host.current().localizedName ?? "MacBook",
          ])
      } else {
        respond(
          fd, HTTPContract.StatusCode.forbidden,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.pairingDeclined])
      }
      return
    }
    guard let authenticatedDevice = validDevice(token) else {
      respond(
        fd, HTTPContract.StatusCode.unauthorized,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.deviceNotPairedOrTokenInvalid])
      return
    }
    ClipStore.shared.markDeviceSeen(id: authenticatedDevice.id)
    if req.method == HTTPContract.Method.post, req.path == HTTPContract.Path.notificationRelay {
      guard let payload = try? JSONDecoder().decode(PhoneNotificationPayload.self, from: req.body),
        payload.isValid
      else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidNotificationPayload])
        return
      }
      switch PhoneNotificationRelay.shared.receive(payload, from: authenticatedDevice) {
      case .delivered:
        respond(
          fd, HTTPContract.StatusCode.ok,
          [
            HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.delivered
          ])
      case .ignored:
        respond(
          fd, HTTPContract.StatusCode.ok,
          [
            HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ignored
          ])
      case .rateLimited:
        respond(
          fd, HTTPContract.StatusCode.tooManyRequests,
          [
            HTTPContract.ResponseKey.error: HTTPServerErrors.notificationRateLimited
          ])
      }
      return
    }
    if req.method == HTTPContract.Method.get, req.path == HTTPContract.Path.notificationReplyWait {
      guard notificationReplyWaiters < 4 else {
        respond(
          fd, HTTPContract.StatusCode.tooManyRequests,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.notificationReplyWaitersLimited])
        return
      }
      notificationReplyWaiters += 1
      Task { @MainActor in
        defer { notificationReplyWaiters -= 1 }
        guard
          let command = await PhoneNotificationRelay.shared.waitForReply(
            deviceID: authenticatedDevice.id),
          let data = try? JSONEncoder().encode(command)
        else {
          self.respond(
            fd, HTTPContract.StatusCode.noContent, raw: Data(),
            contentType: "application/json; charset=utf-8")
          return
        }
        self.respond(
          fd, HTTPContract.StatusCode.ok, raw: data, contentType: "application/json; charset=utf-8")
      }
      return
    }
    if req.method == HTTPContract.Method.post, req.path == HTTPContract.Path.pairIdentity,
      let device = validDevice(token)
    {
      guard let object = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
        let id = object["deviceId"] as? String,
        ClipStore.shared.migrateDeviceIdentity(token: token, id: id)
      else {
        respond(
          fd, HTTPContract.StatusCode.conflict,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.deviceIdentityUpdateFailed])
        return
      }
      MacTransferService.shared.migrateOwner(from: device.id, to: id)
      respond(
        fd, HTTPContract.StatusCode.ok,
        [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok])
      return
    }
    if let device = validDevice(token), routeBuckets(fd, req, device: device) { return }
    if req.method == HTTPContract.Method.post && req.path == HTTPContract.Path.pairUnpair {
      guard let device = validDevice(token), ClipStore.shared.unpairDevice(id: device.id) else {
        respond(
          fd, HTTPContract.StatusCode.internalServerError,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.unpairPersistenceFailed])
        return
      }
      respond(
        fd, HTTPContract.StatusCode.ok,
        [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.unpaired])
      return
    }
    if req.method == HTTPContract.Method.post && req.path == HTTPContract.Path.transfer {
      guard let encoded = req.headers[HTTPContract.Header.transferMetadata],
        let metaData = Data(base64Encoded: encoded),
        let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
        let size = meta["size"] as? NSNumber, size.intValue == req.body.count,
        size.intValue <= maxBody,
        let kind = meta["kind"] as? String, ["text", "image", "file"].contains(kind),
        kind != "text" || String(data: req.body, encoding: .utf8) != nil
      else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidTransfer])
        return
      }
      let checksumMatches =
        (meta["sha256"] as? String).map { $0.isEmpty || $0.lowercased() == Self.sha256(req.body) }
        ?? true
      guard checksumMatches,
        MacTransferService.shared.acceptIncoming(metadata: meta, body: req.body, token: token)
      else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidTransfer])
        return
      }
      respond(
        fd, HTTPContract.StatusCode.ok,
        [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok])
      return
    }
    if req.method == HTTPContract.Method.get && req.path == HTTPContract.Path.inboxWait {
      guard inboxWaiters < 2 else {
        respond(
          fd, HTTPContract.StatusCode.tooManyRequests,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.inboxWaitersLimited])
        return
      }
      inboxWaiters += 1
      Task { @MainActor in
        defer { inboxWaiters -= 1 }
        guard let items = await MacTransferService.shared.waitForInbox(token: token),
          let data = try? JSONSerialization.data(withJSONObject: items)
        else {
          self.respond(
            fd, HTTPContract.StatusCode.unauthorized,
            [HTTPContract.ResponseKey.error: HTTPServerErrors.deviceNoLongerPaired])
          return
        }
        self.respond(
          fd, HTTPContract.StatusCode.ok, raw: data, contentType: "application/json; charset=utf-8")
      }
      return
    }
    if req.method == HTTPContract.Method.get && req.path == HTTPContract.Path.inbox {
      guard let items = MacTransferService.shared.inbox(token: token),
        let json = try? JSONSerialization.data(withJSONObject: items),
        let text = String(data: json, encoding: .utf8)
      else {
        respond(
          fd, HTTPContract.StatusCode.internalServerError,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.inboxUnavailable])
        return
      }
      respond(
        fd, HTTPContract.StatusCode.ok, raw: Data(text.utf8),
        contentType: "application/json; charset=utf-8")
      return
    }
    if req.method == HTTPContract.Method.get && req.path.hasPrefix(HTTPContract.Path.downloadPrefix)
    {
      let transferID =
        String(req.path.dropFirst(HTTPContract.Path.downloadPrefix.count)).removingPercentEncoding
        ?? ""
      guard let file = MacTransferService.shared.download(transferID: transferID, token: token),
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBody,
        let bytes = try? Data(contentsOf: file), bytes.count <= maxBody
      else {
        respond(
          fd, HTTPContract.StatusCode.notFound,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.transferUnavailable])
        return
      }
      respond(fd, HTTPContract.StatusCode.ok, raw: bytes, contentType: "application/octet-stream")
      return
    }
    if req.method == HTTPContract.Method.post && req.path == HTTPContract.Path.inboxAck {
      guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
        let ids = obj["ids"] as? [String],
        MacTransferService.shared.acknowledge(ids: ids, token: token)
      else {
        respond(
          fd, HTTPContract.StatusCode.badRequest,
          [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidAcknowledgement])
        return
      }
      respond(
        fd, HTTPContract.StatusCode.ok,
        [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok])
      return
    }
    if req.method == HTTPContract.Method.post
      && (req.path == HTTPContract.Path.clip || req.path == HTTPContract.Path.clipBatch),
      let obj = try? JSONSerialization.jsonObject(with: req.body)
    {
      let store = ClipStore.shared
      if req.path == HTTPContract.Path.clipBatch, let rows = obj as? [[String: Any]] {
        var count = 0
        for row in rows {
          guard let text = row["text"] as? String else { continue }
          let wireID = row["transferId"] as? String ?? row["id"] as? String ?? UUID().uuidString
          let attempt = TransferIdentity.scoped(owner: validDevice(token)!.id, id: wireID)
          if !store.seenTransferAttempt(attempt) {
            if store.addTransferredItem(
              id: attempt, text: text, appName: row["app"] as? String ?? "Android",
              packageName: row["package"] as? String ?? "",
              timestamp: Date(
                timeIntervalSince1970: ((row["timestamp"] as? NSNumber)?.doubleValue ?? Date()
                  .timeIntervalSince1970 * 1000) / 1000), kind: "text", mimeType: "text/plain",
              attachmentName: nil, attachmentPath: nil, direction: "received",
              sourceDeviceId: validDevice(token)?.id)
            {
              count += 1
            }
          }
        }
        respond(
          fd, HTTPContract.StatusCode.ok,
          [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok, "synced": count])
        return
      }
      if let row = obj as? [String: Any], let text = row["text"] as? String {
        let wireID = row["transferId"] as? String ?? row["id"] as? String ?? UUID().uuidString
        let attempt = TransferIdentity.scoped(owner: validDevice(token)!.id, id: wireID)
        if !store.seenTransferAttempt(attempt) {
          _ = store.addTransferredItem(
            id: attempt, text: text, appName: row["app"] as? String ?? "Android",
            packageName: row["package"] as? String ?? "", timestamp: Date(), kind: "text",
            mimeType: "text/plain", attachmentName: nil, attachmentPath: nil, direction: "received",
            sourceDeviceId: validDevice(token)?.id)
        }
        respond(
          fd, HTTPContract.StatusCode.ok,
          [HTTPContract.ResponseKey.status: HTTPContract.ResponseValue.ok])
        return
      }
      respond(
        fd, HTTPContract.StatusCode.badRequest,
        [HTTPContract.ResponseKey.error: HTTPServerErrors.invalidPayload])
      return
    }
    respond(
      fd, HTTPContract.StatusCode.notFound,
      [HTTPContract.ResponseKey.error: HTTPServerErrors.notFound])
  }

  @MainActor private func validDevice(_ token: String) -> PairedDevice? {
    guard !token.isEmpty else { return nil }
    return ClipStore.shared.pairedDevices.first(where: {
      $0.securePairing == true && !$0.token.isEmpty && $0.token == token
    })
  }

  func respond(_ fd: Int32, _ status: Int, _ object: [String: Any]) {
    let body =
      (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
      ?? Data("{}".utf8)
    respond(fd, status, raw: body, contentType: "application/json; charset=utf-8")
  }
  func respond(
    _ fd: Int32, _ status: Int, raw body: Data, contentType: String,
    extraHeaders: [String: String] = [:]
  ) {
    DispatchQueue.global(qos: .utility).async {
      self.writeResponse(fd, status, body, contentType, extraHeaders)
    }
  }
  private func writeResponse(
    _ fd: Int32, _ status: Int, _ body: Data, _ contentType: String,
    _ extraHeaders: [String: String]
  ) {
    defer {
      close(fd)
      connectionSlots.signal()
    }
    let reasonPhrase = HTTPContract.StatusCode.reasonPhrase(for: status)
    let extra = extraHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
    let responseHeaders =
      "Content-Type: \(contentType)\r\n" + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n" + extra + "Cache-Control: no-store\r\n"
      + "X-Content-Type-Options: nosniff\r\n"
    let head = Data("HTTP/1.1 \(status) \(reasonPhrase)\r\n\(responseHeaders)\r\n".utf8)
    func write(_ data: Data) -> Bool {
      data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return true }
        var sent = 0
        while sent < raw.count {
          let count = send(fd, base.advanced(by: sent), raw.count - sent, 0)
          if count < 0 && errno == EINTR { continue }
          if count <= 0 { return false }
          sent += count
        }
        return true
      }
    }
    if write(head) { _ = write(body) }
  }
  private static func sha256(_ data: Data) -> String {
    #if canImport(CryptoKit)
      return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #else
      return ""
    #endif
  }

}
