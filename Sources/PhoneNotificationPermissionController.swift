import AppKit
import UserNotifications

/** Mediates macOS notification authorization without treating a preference as granted access. */
@MainActor
final class PhoneNotificationPermissionController {
    private let preferences: UserDefaults
    private let relayIsEnabled: () -> Bool
    private let setRelayEnabled: (Bool) -> Void
    private let setPermissionMessage: (String?) -> Void
    private let requestSettingsPrompt: () -> Void

    init(
        preferences: UserDefaults,
        relayIsEnabled: @escaping () -> Bool,
        setRelayEnabled: @escaping (Bool) -> Void,
        setPermissionMessage: @escaping (String?) -> Void,
        requestSettingsPrompt: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.relayIsEnabled = relayIsEnabled
        self.setRelayEnabled = setRelayEnabled
        self.setPermissionMessage = setPermissionMessage
        self.requestSettingsPrompt = requestSettingsPrompt
    }

    func setRelayEnabledByUser(_ enabled: Bool) {
        guard enabled else {
            setRelayEnabled(false)
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                    guard let self else { return }
                    UNUserNotificationCenter.current().getNotificationSettings { latest in
                        Task { @MainActor in
                            self.apply(latest)
                            let allowed = granted && Self.alertsAllowed(latest)
                            if allowed { self.preferences.set(1, forKey: "phoneNotificationRelayConsentVersion") }
                            self.setRelayEnabled(allowed)
                            if !allowed { self.requestSettingsPrompt() }
                        }
                    }
                }
                return
            }

            Task { @MainActor in
                self.apply(settings)
                let allowed = Self.alertsAllowed(settings)
                if allowed { self.preferences.set(1, forKey: "phoneNotificationRelayConsentVersion") }
                self.setRelayEnabled(allowed)
                if !allowed || settings.soundSetting != .enabled { self.requestSettingsPrompt() }
            }
        }
    }

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.apply(settings)
                if !Self.alertsAllowed(settings), self.relayIsEnabled() {
                    self.setRelayEnabled(false)
                }
            }
        }
    }

    func openNotificationSettings() {
        let appSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.vdx.cliptomac")
        let notificationsSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        if let appSettings, NSWorkspace.shared.open(appSettings) { return }
        if let notificationsSettings, NSWorkspace.shared.open(notificationsSettings) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func openFocusSettings() {
        let focusSettings = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")
        if let focusSettings, NSWorkspace.shared.open(focusSettings) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    private func apply(_ settings: UNNotificationSettings) {
        if settings.authorizationStatus == .denied || !Self.alertsAllowed(settings) {
            setPermissionMessage("macOS is blocking ClipToMac alerts. Allow notifications in System Settings to forward Android notifications here.")
        } else if settings.soundSetting == .disabled {
            setPermissionMessage("ClipToMac alerts are allowed, but macOS has disabled their sound. Enable sound in System Settings.")
        } else {
            setPermissionMessage(nil)
        }
    }

    private static func alertsAllowed(_ settings: UNNotificationSettings) -> Bool {
        (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            && settings.alertSetting == .enabled
    }
}
