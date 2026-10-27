import Foundation
import Security
import CryptoKit

/// A persistent P-256 key in Keychain, with a self-signed X.509 identity verified by QR pinning.
final class TLSIdentity {
    static let shared = TLSIdentity()
    private let lock = NSLock()
    private var cached: (SecIdentity, Data)?
    private let tag: Data
    private let certificateDirectory: URL
    init(tag: String = "com.vdx.cliptomac.tls.v3", certificateDirectory: URL? = nil) {
        self.tag = Data(tag.utf8)
        self.certificateDirectory = certificateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipToMac/TLS")
    }

    func load() throws -> (identity: SecIdentity, certificate: Data) {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        let key: SecKey
        if result == errSecSuccess { key = item as! SecKey }
        else if result == errSecItemNotFound {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                    kSecAttrLabel as String: "ClipToMac TLS identity", kSecAttrIsExtractable as String: false, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]]
            guard let created = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else { if let error { throw error.takeRetainedValue() }; throw TLSError.identity }
            key = created
        } else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        // macOS may normalize a certificate's Keychain label to its common name.
        // Persist its public DER explicitly so a restart never silently regenerates the pin.
        try PrivateAppStorage.prepare(certificateDirectory)
        let certificateURL = certificateDirectory.appendingPathComponent(SHA256.hash(data: tag).map { String(format: "%02x", $0) }.joined() + ".der")
        let der: Data
        if FileManager.default.fileExists(atPath: certificateURL.path) { der = try Data(contentsOf: certificateURL) }
        else { der = try Self.certificate(key: key) }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData), let certificateKey = SecCertificateCopyKey(cert),
              let expectedKey = SecKeyCopyPublicKey(key),
              SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(expectedKey, nil) as Data? else { throw TLSError.identity }
        let added = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert] as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let identity else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let data = SecCertificateCopyData(cert) as Data
        if !FileManager.default.fileExists(atPath: certificateURL.path) { try PrivateAppStorage.write(data, to: certificateURL) }
        cached = (identity, data)
        return (identity, data)
    }
    func fingerprint() throws -> String { SHA256.hash(data: try load().certificate).map { String(format: "%02x", $0) }.joined() }

    #if CLIPTOMAC_TRANSFER_TEST
    func cleanupTestIdentity() {
        precondition(String(decoding: tag, as: UTF8.self).hasPrefix("com.vdx.cliptomac.test."))
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        if let cached, let certificate = SecCertificateCreateWithData(nil, cached.1 as CFData),
           let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate), let serial = SecCertificateCopySerialNumberData(certificate, nil) {
            SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrIssuer as String: issuer,
                kSecAttrSerialNumber as String: serial] as CFDictionary)
        }
    }
    #endif

    /// Standard DER/X.509 encoding only; all key generation/signing is performed by Security.framework.
    private static func certificate(key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key), let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { throw TLSError.identity }
        let signatureAlgorithm = DER.sequence(DER.oid([0x2A,0x86,0x48,0xCE,0x3D,0x04,0x03,0x02])) // ecdsa-with-SHA256
        let name = DER.sequence(DER.value(0x31, DER.sequence(DER.oid([0x55,0x04,0x03]) + DER.value(0x0C, Data("ClipToMac".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyMMddHHmmss'Z'"
        let now = Date()
        let validity = DER.sequence(DER.value(0x17, Data(formatter.string(from: now.addingTimeInterval(-86400)).utf8)) + DER.value(0x17, Data(formatter.string(from: now.addingTimeInterval(10 * 365 * 86400)).utf8)))
        let algorithm = DER.sequence(DER.oid([0x2A,0x86,0x48,0xCE,0x3D,0x02,0x01]) + DER.oid([0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07]))
        let spki = DER.sequence(algorithm + DER.value(0x03, Data([0]) + point))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw TLSError.identity }
        // DER INTEGERs must be minimally encoded; Android's parser rejects a redundant zero prefix.
        while serial.count > 1 && serial[0] == 0 { serial.removeFirst() }
        var serialBytes = Data(serial)
        if serial[0] & 0x80 != 0 { serialBytes.insert(0, at: 0) }
        let tbs = DER.sequence(DER.value(0xA0, DER.value(0x02, Data([2]))) + DER.value(0x02, serialBytes) + signatureAlgorithm + name + validity + name + spki)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else { if let error { throw error.takeRetainedValue() }; throw TLSError.identity }
        return DER.sequence(tbs + signatureAlgorithm + DER.value(0x03, Data([0]) + signature))
    }
    enum TLSError: Error { case identity }
}

private enum DER {
    static func value(_ tag: UInt8, _ bytes: Data) -> Data {
        var count = bytes.count; var length: [UInt8] = []
        if count < 128 { length = [UInt8(count)] }
        else { while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }; length.insert(0x80 | UInt8(length.count), at: 0) }
        return Data([tag] + length) + bytes
    }
    static func sequence(_ bytes: Data) -> Data { value(0x30, bytes) }
    static func oid(_ bytes: [UInt8]) -> Data { value(0x06, Data(bytes)) }
}
