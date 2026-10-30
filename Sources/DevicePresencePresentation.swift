import Foundation

public enum DeviceConnectionState: Equatable {
    case unpaired, securePairingRequired, awaitingActivity, connected
}

/// Derives the user-facing connection state from authenticated device activity.
struct DevicePresencePresentation {
    let devices: [PairedDevice]
    let lastSeen: [String: Date]

    func state(at now: Date = Date()) -> DeviceConnectionState {
        guard !devices.isEmpty else { return .unpaired }
        let secure = devices.filter { $0.securePairing == true }
        guard !secure.isEmpty else { return .securePairingRequired }
        return secure.contains { isRecentlyActive($0, at: now) } ? .connected : .awaitingActivity
    }

    func summary(at now: Date = Date()) -> String {
        switch state(at: now) {
        case .unpaired: return "Not paired"
        case .securePairingRequired: return "Secure pairing required"
        case .awaitingActivity:
            let secure = devices.filter { $0.securePairing == true }
            return secure.count == 1 ? "Paired · " + secure[0].name : "Paired · \(secure.count) phones"
        case .connected:
            let active = devices.filter { $0.securePairing == true && isRecentlyActive($0, at: now) }
            return active.count == 1 ? "Connected · " + active[0].name : "Connected · \(active.count) phones"
        }
    }

    func explanation(at now: Date = Date()) -> String {
        switch state(at: now) {
        case .unpaired: return "No phone is paired. Scan a pairing QR from the Android app."
        case .securePairingRequired: return "Your saved phone uses the older pairing. Scan a fresh QR once to enable encrypted transfers."
        case .awaitingActivity: return "Paired · waiting for phone activity."
        case .connected: return "Recent authenticated phone activity over the encrypted connection."
        }
    }

    private func isRecentlyActive(_ device: PairedDevice, at now: Date) -> Bool {
        guard let seen = lastSeen[device.id] else { return false }
        let age = now.timeIntervalSince(seen)
        return age >= 0 && age < 60
    }
}
