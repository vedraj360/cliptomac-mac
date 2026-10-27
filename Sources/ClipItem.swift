import Foundation

public enum ClipKind: String, Codable, CaseIterable { case text, image, file }

public enum KnownApp: String, CaseIterable, Codable, Hashable {
    case twitter = "X / Twitter", chrome = "Chrome", whatsApp = "WhatsApp", instagram = "Instagram", youtube = "YouTube", reddit = "Reddit", notes = "Notes", brave = "Brave", safari = "Safari", firefox = "Firefox", telegram = "Telegram", generic = "Other"
    public var iconSymbol: String {
        switch self { case .twitter: return "bubble.left.and.text.bubble.right.fill"; case .chrome: return "globe"; case .whatsApp: return "message.fill"; case .instagram: return "camera.fill"; case .youtube: return "play.rectangle.fill"; case .reddit: return "flame.fill"; case .notes: return "note.text"; case .brave: return "shield.fill"; case .safari: return "safari.fill"; case .firefox: return "globe.americas.fill"; case .telegram: return "paperplane.fill"; case .generic: return "arrow.down.left.and.arrow.up.right" }
    }
    public static func resolve(packageName: String, appName: String) -> KnownApp {
        let p = packageName.lowercased(), n = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ids: [(KnownApp,[String],[String])] = [(.twitter,["com.twitter.android","com.x.android"],["x","twitter"]),(.chrome,["com.android.chrome","com.google.chrome"],["chrome"]),(.whatsApp,["com.whatsapp"],["whatsapp"]),(.instagram,["com.instagram.android","com.instagram"],["instagram"]),(.youtube,["com.google.android.youtube"],["youtube"]),(.reddit,["com.reddit.frontpage","com.reddit"],["reddit"]),(.notes,["com.google.android.keep"],["notes","keep","memo"]),(.brave,["com.brave.browser"],["brave"]),(.safari,["com.apple.mobilesafari"],["safari"]),(.firefox,["org.mozilla.firefox"],["firefox"]),(.telegram,["org.telegram.messenger"],["telegram"])]
        for (app, packages, names) in ids where packages.contains(p) || names.contains(n) { return app }
        return .generic
    }
}

public struct ClipItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var text: String
    public var appName: String
    public var packageName: String
    public var timestamp: Date
    public var kind: ClipKind
    public var mimeType: String?
    public var attachmentName: String?
    public var attachmentPath: String?
    public var sourceDeviceId: String?
    public var direction: String
    public var isPinned: Bool
    public var collection: String?
    public var repeatCount: Int
    public var updatedAt: Date
    public var transferID: String
    public var contentHash: String?
    public var deliveryState: String
    public var sourceApp: KnownApp { KnownApp.resolve(packageName: packageName, appName: appName) }

    public init(id: UUID = UUID(), text: String, appName: String = "Android", packageName: String = "", timestamp: Date = Date(), kind: ClipKind = .text, mimeType: String? = nil, attachmentName: String? = nil, attachmentPath: String? = nil, sourceDeviceId: String? = nil, direction: String = "received", isPinned: Bool = false, collection: String? = nil, repeatCount: Int = 1, updatedAt: Date? = nil, transferID: String = "", deliveryState: String = "delivered", contentHash: String? = nil) {
        self.id=id; self.text=text; self.appName=appName; self.packageName=packageName; self.timestamp=timestamp; self.kind=kind; self.mimeType=mimeType; self.attachmentName=attachmentName; self.attachmentPath=attachmentPath; self.sourceDeviceId=sourceDeviceId; self.direction=direction; self.isPinned=isPinned; self.collection=collection; self.repeatCount=repeatCount; self.updatedAt=updatedAt ?? timestamp; self.transferID=transferID; self.deliveryState=deliveryState; self.contentHash=contentHash
    }
    private enum CodingKeys: String, CodingKey { case id,text,appName,packageName,timestamp,kind,mimeType,attachmentName,attachmentPath,sourceDeviceId,direction,isPinned,collection,repeatCount,updatedAt,transferID,deliveryState,contentHash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(); text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? "Android"; packageName = try c.decodeIfPresent(String.self, forKey: .packageName) ?? ""
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date(); kind = try c.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .text
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType); attachmentName = try c.decodeIfPresent(String.self, forKey: .attachmentName); attachmentPath = try c.decodeIfPresent(String.self, forKey: .attachmentPath)
        sourceDeviceId = try c.decodeIfPresent(String.self, forKey: .sourceDeviceId); direction = try c.decodeIfPresent(String.self, forKey: .direction) ?? "received"
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false; collection = try c.decodeIfPresent(String.self, forKey: .collection)
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1; updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? timestamp
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        transferID = try c.decodeIfPresent(String.self, forKey: .transferID) ?? ""; deliveryState = try c.decodeIfPresent(String.self, forKey: .deliveryState) ?? "delivered"
    }
    public var isURL: Bool { guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { let s=text.trimmingCharacters(in:.whitespacesAndNewlines); return s.hasPrefix("http://") || s.hasPrefix("https://") }; let s=text.trimmingCharacters(in:.whitespacesAndNewlines); let m=detector.matches(in:s, options:[], range:NSRange(location:0,length:s.utf16.count)); return m.count == 1 && m.first?.range.length == s.utf16.count }
    public var relativeTime: String { let f=RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f.localizedString(for: timestamp, relativeTo: Date()) }
    public var exactTime: String { let f=DateFormatter(); f.timeStyle = .short; return f.string(from: timestamp) }
}
