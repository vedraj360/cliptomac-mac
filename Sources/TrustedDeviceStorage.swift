import Foundation
import Security

protocol PairingSecretVault {
    func read(_ reference: String) throws -> String
    func write(_ secret: String, reference: String) throws
    func remove(_ reference: String)
}

struct KeychainPairingVault: PairingSecretVault {
    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.vdx.cliptomac.pairing.v1",
         kSecAttrAccount as String: reference, kSecAttrSynchronizable as String: false]
    }
    func read(_ reference: String) throws -> String {
        var q = query(reference); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return secret
    }
    func write(_ secret: String, reference: String) throws {
        var q = query(reference)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "ClipToMac paired device"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func remove(_ reference: String) { SecItemDelete(query(reference) as CFDictionary) }
}

/// JSON stores device metadata and an opaque reference; the bearer token lives in Keychain.
final class TrustedDeviceStorage {
    private struct Record: Codable {
        let id: String; let name: String; let pairedAt: Date; let credentialRef: String; let securePairing: Bool?
    }
    private let url: URL
    private let vault: PairingSecretVault
    private var loadFailed = false
    private var references: [String: (token: String, reference: String)] = [:]
    init(url: URL, vault: PairingSecretVault = KeychainPairingVault()) { self.url = url; self.vault = vault }

    func load() throws -> [PairedDevice] {
        do {
            let devices = try loadRecords()
            loadFailed = false
            return devices
        } catch { loadFailed = true; throw error }
    }

    private func loadRecords() throws -> [PairedDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if let records = try? JSONDecoder().decode([Record].self, from: data) {
            var loaded: [String: (token: String, reference: String)] = [:]
            let devices = try records.map { record -> PairedDevice in
                let token = try vault.read(record.credentialRef)
                loaded[record.id] = (token, record.credentialRef)
                return PairedDevice(id: record.id, name: record.name, token: token, pairedAt: record.pairedAt, securePairing: record.securePairing)
            }
            references = loaded
            return devices
        }
        let legacy = try JSONDecoder().decode([PairedDevice].self, from: data)
        // Migration may be retried after a temporarily locked Keychain becomes available.
        let previousFailure = loadFailed; loadFailed = false
        do { try save(legacy) } catch { loadFailed = previousFailure; throw error }
        return legacy
    }

    func save(_ devices: [PairedDevice]) throws {
        guard !loadFailed else { throw NSError(domain: "ClipToMacCredentialStorage", code: 2) }
        var next: [String: (token: String, reference: String)] = [:]
        var created: [String] = []
        do {
            let records = try devices.map { device -> Record in
                guard !device.token.isEmpty else { throw NSError(domain: "ClipToMacCredentialStorage", code: 1) }
                let reference: String
                if let old = references[device.id], old.token == device.token { reference = old.reference }
                else {
                    reference = UUID().uuidString
                    try vault.write(device.token, reference: reference); created.append(reference)
                }
                next[device.id] = (device.token, reference)
                return Record(id: device.id, name: device.name, pairedAt: device.pairedAt, credentialRef: reference, securePairing: device.securePairing)
            }
            try PrivateAppStorage.write(JSONEncoder().encode(records), to: url)
        } catch { created.forEach { vault.remove($0) }; throw error }
        let retained = Set(next.values.map { $0.reference })
        references.values.filter { !retained.contains($0.reference) }.forEach { vault.remove($0.reference) }
        references = next
    }
}
