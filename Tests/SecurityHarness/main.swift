import Foundation

struct PairedDevice: Codable {
    let id: String; let name: String; let token: String; let pairedAt: Date; let securePairing: Bool?
    init(id: String, name: String, token: String, pairedAt: Date = Date(), securePairing: Bool? = nil) { self.id = id; self.name = name; self.token = token; self.pairedAt = pairedAt; self.securePairing = securePairing }
}
final class MemoryVault: PairingSecretVault {
    var secrets: [String: String] = [:]
    var failWrites = false
    func read(_ reference: String) throws -> String {
        guard let value = secrets[reference] else { throw CocoaError(.fileReadNoSuchFile) }; return value
    }
    func write(_ secret: String, reference: String) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }; secrets[reference] = secret
    }
    func remove(_ reference: String) { secrets.removeValue(forKey: reference) }
}
func check(_ condition: @autoclosure () throws -> Bool, _ message: String = "Security assertion failed") throws {
    let valid = try condition(); precondition(valid, message)
}
@main struct SecurityTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipToMac-security-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PrivateAppStorage.prepare(root)
        let url = root.appendingPathComponent("trusted_devices.json")
        let device = PairedDevice(id: "phone", name: "Phone", token: "fixture-secret")
        try JSONEncoder().encode([device]).write(to: url)
        try PrivateAppStorage.prepare(root)
        let vault = MemoryVault()
        let storage = TrustedDeviceStorage(url: url, vault: vault)
        let migrated = try storage.load()
        try check(migrated.first?.token == device.token && vault.secrets.count == 1)
        try check(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains(device.token), "Plaintext token remained in JSON")
        func permissions(_ path: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue & 0o777 }
        try check(try permissions(root) == 0o700)
        try check(try permissions(url) == 0o600)
        let newDevice = PairedDevice(id: "phone", name: "Phone", token: "rotated-fixture-secret")
        vault.failWrites = true
        do { try storage.save([newDevice]); preconditionFailure("Failed Keychain write was accepted") } catch {}
        try check(try storage.load().first?.token == device.token && vault.secrets.count == 1)
        vault.failWrites = false
        try storage.save([newDevice])
        try check(vault.secrets.count == 1 && !vault.secrets.values.contains(device.token), "Old token was not removed")
        let reloaded = TrustedDeviceStorage(url: url, vault: vault)
        try check(try reloaded.load().first?.token == newDevice.token)
        let savedSecrets = vault.secrets
        vault.secrets.removeAll()
        do { _ = try reloaded.load(); preconditionFailure("Missing Keychain secret did not fail closed") } catch {}
        do { try reloaded.save([]); preconditionFailure("Unavailable credentials allowed metadata overwrite") } catch {}
        vault.secrets = savedSecrets
        _ = try reloaded.load()
        try storage.save([])
        try check(vault.secrets.isEmpty && (try storage.load()).isEmpty)
        let failedURL = root.appendingPathComponent("missing-parent/metadata.json")
        do { try TrustedDeviceStorage(url: failedURL, vault: vault).save([device]); preconditionFailure("Failed metadata commit accepted") } catch {}
        try check(vault.secrets.isEmpty, "Failed metadata commit leaked newly created secret")
        let legacyURL = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode([device]).write(to: legacyURL)
        vault.failWrites = true
        do { _ = try TrustedDeviceStorage(url: legacyURL, vault: vault).load(); preconditionFailure("Failed legacy migration accepted") } catch {}
        try check(try JSONDecoder().decode([PairedDevice].self, from: Data(contentsOf: legacyURL)).first?.token == device.token, "Failed migration destroyed credentials")
        try check(PairingRequestPolicy.valid(id: "android-1234567890abcdef", name: "Phone", code: "123456"))
        try check(!PairingRequestPolicy.valid(id: "../phone", name: "Phone", code: "123456"))
        try check(!PairingRequestPolicy.valid(id: "phone", name: "Phone\nApprove", code: "123456"))
        try check(!PairingRequestPolicy.valid(id: "phone", name: "Phone", code: "123"))
        let policy = PairingRequestPolicy()
        try check(policy.begin(now: 0)); try check(!policy.begin(now: 0)); policy.finish()
        try check(policy.begin(now: 1)); policy.finish()
        try check(policy.begin(now: 2)); policy.finish()
        try check(!policy.begin(now: 3)); try check(policy.begin(now: 61)); policy.finish()
        let a = try PairingRequestPolicy.token(), b = try PairingRequestPolicy.token()
        try check(a != b && Data(base64Encoded: a)?.count == 32)
        if CommandLine.arguments.contains("--keychain-smoke") {
            let keychain = KeychainPairingVault(), reference = "security-fixture-" + UUID().uuidString
            defer { keychain.remove(reference) }
            try keychain.write("isolated-test-secret", reference: reference)
            try check(try keychain.read(reference) == "isolated-test-secret")
            print("PASS isolated Keychain write/read/removal")
        }
        print("PASS security: credential migration/rotation/revocation, rollback, missing-secret rejection, private permissions, pairing validation/rate limits/randomness")
    }
}
