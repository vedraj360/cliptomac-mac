import Foundation
import ServiceManagement

public class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()
    
    private let agentPlistURL: URL = {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        return launchAgentsDir.appendingPathComponent("com.vdx.cliptomac.plist")
    }()
    
    public var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentPlistURL.path)
        } else {
            return FileManager.default.fileExists(atPath: agentPlistURL.path)
        }
    }
    
    public func setEnabled(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                configureLaunchAgent(enable: enable)
            }
        } else {
            configureLaunchAgent(enable: enable)
        }
    }
    
    private func configureLaunchAgent(enable: Bool) {
        if enable {
            let appPath = Bundle.main.bundlePath
            let execPath = Bundle.main.executablePath ?? "\(appPath)/Contents/MacOS/ClipToMac"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.vdx.cliptomac</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? plistContent.write(to: agentPlistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: agentPlistURL)
        }
    }
}
