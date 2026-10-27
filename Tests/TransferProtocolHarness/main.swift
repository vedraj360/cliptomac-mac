import Foundation
import CryptoKit
import Darwin

@main struct Harness {
    static let port: UInt16 = 15768
    @MainActor static func main() async throws {
        let store = ClipStore.shared
        let first = PairedDevice(id: "test-a", name: "Test A", token: "token-a")
        let second = PairedDevice(id: "test-b", name: "Test B", token: "token-b")
        store.pairedDevices = [first, second]
        HTTPServer.shared.start(port: Int(port))
        defer { HTTPServer.shared.stop() }
        try await Task.sleep(nanoseconds: 250_000_000)

        let browser = try await requestAsync("POST /pair/request HTTP/1.1\r\nHost: localhost\r\nOrigin: https://untrusted.invalid\r\nContent-Length: 0\r\n\r\n")
        precondition(status(browser) == 403, "Browser-origin pairing accepted")
        precondition(!String(decoding: browser, as: UTF8.self).contains("Access-Control-Allow-Origin"))
        let invalidPair = try await requestAsync("POST /pair/request HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}")
        precondition(status(invalidPair) == 400, "Malformed pairing accepted")
        let invalidPing = try await requestAsync("GET /ping HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: invalid-token\r\n\r\n")
        precondition(status(invalidPing) == 401, "Revoked/invalid pairing looked connected through ping")
        let noAuth = try await requestAsync("GET /inbox HTTP/1.1\r\nHost: localhost\r\n\r\n")
        precondition(status(noAuth) == 401, "Unauthenticated inbox accepted")
        let pingResponse = try await requestAsync("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let ping = try JSONSerialization.jsonObject(with: body(pingResponse)) as! [String: Any]
        precondition(ping["pairedDevice"] == nil, "Public ping leaked paired-phone names")

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-protocol-fixture-\(UUID().uuidString).bin")
        let fileBytes = Data((0..<140_000).map { UInt8($0 % 251) }); try fileBytes.write(to: source)
        if CommandLine.arguments.contains("--buckets") {
            let handle = try FileHandle(forWritingTo: source)
            let chunk = Data(repeating: 0x6B, count: 64 * 1024)
            for _ in 0..<528 { try handle.write(contentsOf: chunk) }
            try handle.write(contentsOf: Data(repeating: 0x1F, count: 123)); try handle.close()
        }
        if CommandLine.arguments.contains("--large") {
            let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: UInt64(5) * 1024 * 1024 * 1024 + 123); try handle.close()
        }
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.attachmentDirectory) }
        let transferID = try await MacTransferService.shared.sendFile(source, to: first)
        if CommandLine.arguments.contains("--serve") {
            print("READY isolated interop server on port \(port)")
            fflush(stdout)
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: "/tmp/cliptomac-stop-interop") { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return
        }
        let duplicateFileID = try await MacTransferService.shared.sendFile(source, to: first)
        precondition(duplicateFileID == transferID, "same pending file was queued twice")
        let listingA = try await requestAsync("GET /inbox HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n")
        let jsonA = try JSONSerialization.jsonObject(with: body(listingA)) as! [[String: Any]]
        precondition(jsonA.count == 1 && jsonA[0]["transferId"] as? String == transferID, "outbound inbox missing")
        let listingB = try await requestAsync("GET /inbox HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-b\r\n\r\n")
        let jsonB = try JSONSerialization.jsonObject(with: body(listingB)) as! [[String: Any]]
        precondition(jsonB.isEmpty, "inbox leaked across paired devices")
        let download = try await requestAsync("GET /download/\(transferID) HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n")
        precondition(status(download) == 200 && body(download) == fileBytes, "binary download mismatch")
        let forbidden = try await requestAsync("GET /download/\(transferID) HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-b\r\n\r\n")
        precondition(status(forbidden) == 404, "download leaked across devices")
        let unauth = try await requestAsync("GET /inbox HTTP/1.1\r\nHost: localhost\r\n\r\n")
        precondition(status(unauth) == 401, "unauthenticated access accepted")

        let payload = Data((0..<140_123).map { UInt8(($0 * 7) % 251) })
        let meta: [String: Any] = ["transferId":"incoming-attempt","kind":"file","mimeType":"application/octet-stream","name":"payload.bin","size":payload.count,"sha256":SHA256.hash(data: payload).map { String(format:"%02x",$0) }.joined(),"timestamp":1_798_000_000_000,"app":"test","package":"test"]
        let encoded = Data(try JSONSerialization.data(withJSONObject: meta)).base64EncodedString()
        let requestHead = Data("POST /transfer HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\nX-ClipToMac-Metadata: \(encoded)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        let accepted = try await requestAsync(requestHead + payload, fragmentSize: 997)
        precondition(status(accepted) == 200 && store.received[TransferIdentity.scoped(owner: first.id, id: "incoming-attempt")]?.1 != nil, "fragmented transfer failed")
        let retried = try await requestAsync(requestHead + payload, fragmentSize: 4093)
        precondition(status(retried) == 200 && store.received.count == 1, "retry was not idempotent")
        let otherHead = Data("POST /transfer HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-b\r\nX-ClipToMac-Metadata: \(encoded)\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        let otherResult = try await requestAsync(otherHead + payload)
        precondition(status(otherResult) == 200 && store.received[TransferIdentity.scoped(owner: second.id, id: "incoming-attempt")] != nil, "One device suppressed another device's transfer ID")
        var badMeta = meta; badMeta["transferId"] = "bad-hash"; badMeta["sha256"] = "00"
        let badHeader = Data("POST /transfer HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\nX-ClipToMac-Metadata: \(Data(try JSONSerialization.data(withJSONObject: badMeta)).base64EncodedString())\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        let badResponse = try await requestAsync(badHeader + payload, fragmentSize: 4096)
        precondition(status(badResponse) == 400, "bad checksum accepted")
        let huge = try await requestAsync("POST /transfer HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\nContent-Length: 26214401\r\n\r\n")
        precondition(status(huge) == 400, "oversize request accepted")
        let ackBody = Data(try JSONSerialization.data(withJSONObject: ["ids":[transferID]]))
        let ack = try await requestAsync(Data("POST /inbox/ack HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\nContent-Length: \(ackBody.count)\r\n\r\n".utf8) + ackBody)
        precondition(status(ack) == 200, "ack failed")
        let afterAck = try await requestAsync("GET /inbox HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n")
        let jsonAfterAck = try JSONSerialization.jsonObject(with: body(afterAck)) as! [[String: Any]]
        precondition(jsonAfterAck.isEmpty, "ack did not durably clear inbox")
        let waiter = Task { try await requestAsync("GET /inbox/wait HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n") }
        try await Task.sleep(nanoseconds: 250_000_000)
        let secondWaiter = Task { try await requestAsync("GET /inbox/wait HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n") }
        try await Task.sleep(nanoseconds: 250_000_000)
        let saturated = try await requestAsync("GET /inbox/wait HTTP/1.1\r\nHost: localhost\r\nX-ClipToMac-Token: token-a\r\n\r\n")
        precondition(status(saturated) == 429, "Inbox waiters consumed all request capacity")
        let responsive = try await requestAsync("GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n")
        precondition(status(responsive) == 200, "Long-poll requests starved ping")
        let wakeID = try MacTransferService.shared.sendText("automatic receive", to: first)
        let wakeResponse = try await waiter.value
        _ = try await secondWaiter.value
        let wakeItems = try JSONSerialization.jsonObject(with: body(wakeResponse)) as! [[String: Any]]
        precondition(wakeItems.first?["transferId"] as? String == wakeID, "waiting phone was not notified")
        try await bucketChecks()
        print("PASS transfer protocol: automatic inbox wake, pending-file dedupe, fragmentation, binary integrity, auth/isolation, checksum, size bound, idempotence, ACK")
    }

    static func requestAsync(_ text: String) async throws -> Data { try await requestAsync(Data(text.utf8)) }
    static func requestAsync(_ data: Data, fragmentSize: Int = Int.max) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { do { continuation.resume(returning: try request(data, fragmentSize: fragmentSize)) } catch { continuation.resume(throwing: error) } }
        }
    }
    static func request(_ data: Data, fragmentSize: Int = Int.max) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw NSError(domain:"socket", code:1) }
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw NSError(domain:"connect", code:Int(errno)) }
        var index = 0
        while index < data.count { let count = min(fragmentSize, data.count-index); let sent = data.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by:index), count, 0) }; guard sent > 0 else { throw NSError(domain:"send", code:Int(errno)) }; index += sent; if fragmentSize < 8192 { Thread.sleep(forTimeInterval:0.0002) } }
        var result = Data(); var buf = [UInt8](repeating:0,count:64*1024)
        while true { let n = recv(fd,&buf,buf.count,0); if n <= 0 { break }; result.append(contentsOf:buf.prefix(n)) }
        return result
    }
    static func status(_ data: Data) -> Int { Int(String(decoding:data.prefix(64),as:UTF8.self).split(separator:" ").dropFirst().first ?? "0") ?? 0 }
    static func body(_ response: Data) -> Data { let delimiter = Data("\r\n\r\n".utf8); guard let range=response.range(of:delimiter) else { return Data() }; return Data(response[range.upperBound...]) }
}
