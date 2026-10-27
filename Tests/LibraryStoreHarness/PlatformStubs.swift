import Foundation
final class LaunchAtLoginManager { static let shared = LaunchAtLoginManager(); var isEnabled = false; func setEnabled(_ enabled: Bool) {} }
extension Notification.Name { static let clipShortcutChanged = Notification.Name("testShortcutChanged") }
