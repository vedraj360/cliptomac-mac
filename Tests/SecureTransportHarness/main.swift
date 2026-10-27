import Foundation
import CryptoKit

@main struct SecureServerFixture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply an isolated fixture directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try PrivateAppStorage.prepare(root)
        let tag = "com.vdx.cliptomac.test." + UUID().uuidString
        let identity = TLSIdentity(tag: tag, certificateDirectory: root.appendingPathComponent("identity"))
        defer { HTTPServer.shared.stop(); identity.cleanupTestIdentity(); try? FileManager.default.removeItem(at: ClipStore.shared.attachmentDirectory) }
        let credentials = try identity.load()
        let restored = try TLSIdentity(tag: tag, certificateDirectory: root.appendingPathComponent("identity")).load()
        precondition(credentials.certificate == restored.certificate, "TLS identity changed across a restart")
        try PrivateAppStorage.write(credentials.certificate, to: root.appendingPathComponent("certificate.der"))
        let base64 = credentials.certificate.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        try PrivateAppStorage.write(Data(("-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n").utf8), to: root.appendingPathComponent("certificate.pem"))
        let legacy = PairedDevice(id: "legacy-phone", name: "Legacy", token: "legacy-token", securePairing: false)
        ClipStore.shared.pairedDevices = [legacy]
        SecurePairing.shared.open(host: "127.0.0.1", port: 15769, identity: identity)
        guard let payload = SecurePairing.shared.payload else { throw TLSIdentity.TLSError.identity }
        try PrivateAppStorage.write(Data(payload.utf8), to: root.appendingPathComponent("enrollment.json"))
        if let png = PairingQRCode.png(payload) { try PrivateAppStorage.write(png, to: root.appendingPathComponent("qr.png")) }
        try HTTPServer.shared.startTLS(port: 15769, identity: identity)
        try await Task.sleep(nanoseconds: 500_000_000)
        try PrivateAppStorage.write(Data("ready".utf8), to: root.appendingPathComponent("ready"))
        let source = root.appendingPathComponent("outbound.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let sourceHandle = try FileHandle(forWritingTo: source)
        for _ in 0..<256 { try sourceHandle.write(contentsOf: Data(repeating: 0x5A, count: 64 * 1024)) }
        try sourceHandle.write(contentsOf: Data(repeating: 0x27, count: 123)); try sourceHandle.close()
        var seeded = Set<String>()
        for _ in 0..<1200 {
            for device in ClipStore.shared.pairedDevices where device.securePairing == true && !seeded.contains(device.id) {
                seeded.insert(device.id)
                _ = try await MacTransferService.shared.sendFile(source, to: device)
            }
            let renewal = root.appendingPathComponent("renew")
            if FileManager.default.fileExists(atPath: renewal.path) {
                try? FileManager.default.removeItem(at: renewal)
                SecurePairing.shared.open(host: "127.0.0.1", port: 15769, identity: identity)
                if let payload = SecurePairing.shared.payload { try PrivateAppStorage.write(Data(payload.utf8), to: root.appendingPathComponent("enrollment.json")); if let png = PairingQRCode.png(payload) { try PrivateAppStorage.write(png, to: root.appendingPathComponent("qr.png")) } }
                try PrivateAppStorage.write(Data("renewed".utf8), to: root.appendingPathComponent("renewed"))
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        SecurePairing.shared.close()
        try await Task.sleep(nanoseconds: 200_000_000)
    }
}
