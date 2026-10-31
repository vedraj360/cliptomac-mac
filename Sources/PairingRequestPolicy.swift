import Foundation
import Security

/// Abuse controls for the legacy pairing endpoint. This is not cryptographic peer verification.
@MainActor final class PairingRequestPolicy {
    private var attempts: [TimeInterval] = []
    private var presenting = false
    func begin(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        attempts.removeAll { now - $0 >= 60 }
        guard !presenting, attempts.count < 3 else { return false }
        attempts.append(now); presenting = true; return true
    }
    func finish() { presenting = false }
    static func valid(id: String, name: String, code: String) -> Bool {
        ClipToMacProtocol.isValidTransferIdentifier(id) &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128 &&
        name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0) } &&
        ClipToMacProtocol.isPairingCode(code)
    }
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        return Data(bytes).base64EncodedString()
    }
}
