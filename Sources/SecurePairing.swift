import Foundation
import Combine
import CryptoKit

/// The QR is the out-of-band trust channel. Its random enrollment nonce is short-lived and single-use.
@MainActor final class SecurePairing: ObservableObject {
    static let shared = SecurePairing()
    @Published private(set) var payload: String?
    @Published private(set) var expiresAt: Date?
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var expired = false
    private let clock: () -> TimeInterval
    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    @Published var error: String?
    private var nonce: String?
    private var deadline: TimeInterval = 0
    private var timer: Timer?
    func open(host: String, port: Int, identity: TLSIdentity = .shared) {
        close(); error = nil
        do {
            let value = try PairingRequestPolicy.token()
            let fingerprint = try identity.fingerprint()
            let expiry = Date().addingTimeInterval(120)
            let object: [String: Any] = ["service": "ClipToMac", "version": 3, "host": host, "port": port,
                "fingerprint": fingerprint, "certificate": try identity.load().certificate.base64EncodedString(), "nonce": value, "expires": Int(expiry.timeIntervalSince1970)]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            nonce = value; deadline = clock() + 120
            remainingSeconds = 120; expired = false
            expiresAt = expiry; payload = String(decoding: data, as: UTF8.self)
            let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshRemaining() }
            }
            timer = ticker
            RunLoop.main.add(ticker, forMode: .common)
        } catch { self.error = "Could not access the secure Mac identity. Unlock your Keychain and try again." }
    }
    func consume(_ candidate: String) -> Bool {
        refreshRemaining()
        guard let nonce, clock() < deadline, candidate.utf8.count <= 128 else { return false }
        let a = Array(SHA256.hash(data: Data(nonce.utf8))), b = Array(SHA256.hash(data: Data(candidate.utf8)))
        let difference = zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0 else { return false }
        close(); return true
    }
    func refreshRemaining() {
        guard nonce != nil else { return }
        // Wall time catches sleep; monotonic time prevents clock rollback extending validity.
        let awakeRemaining = Int(ceil(deadline - clock()))
        let wallRemaining = Int(ceil(expiresAt?.timeIntervalSinceNow ?? 0))
        remainingSeconds = max(0, min(awakeRemaining, wallRemaining))
        if remainingSeconds == 0 { close(); expired = true }
    }
    func close() { timer?.invalidate(); timer = nil; nonce = nil; deadline = 0; payload = nil; expiresAt = nil; remainingSeconds = 0; expired = false }
}
