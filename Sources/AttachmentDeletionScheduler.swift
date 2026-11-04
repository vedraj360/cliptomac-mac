import Foundation

/** Defers local attachment deletion until the library's Undo window has ended. */
final class AttachmentDeletionScheduler {
    private let preferences: SQLitePreferences
    private let preferenceKey = "pendingAttachmentDeletions"

    init(preferences: SQLitePreferences) {
        self.preferences = preferences
    }

    func schedule(for clips: [ClipItem], attachmentDirectory: URL, delay: TimeInterval = 10) {
        var pending = preferences.dictionary(forKey: preferenceKey) as? [String: Double] ?? [:]
        let root = attachmentRoot(attachmentDirectory)
        for clip in clips {
            guard let path = clip.attachmentPath else { continue }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard canonical.hasPrefix(root) else { continue }
            pending[canonical] = Date().timeIntervalSince1970 + delay
        }
        preferences.set(pending, forKey: preferenceKey)
    }

    func cancel(for clips: [ClipItem]) {
        var pending = preferences.dictionary(forKey: preferenceKey) as? [String: Double] ?? [:]
        for clip in clips {
            guard let path = clip.attachmentPath else { continue }
            pending.removeValue(forKey: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path)
        }
        preferences.set(pending, forKey: preferenceKey)
    }

    @discardableResult
    func sweepExpired(referencedFiles: Set<String>, attachmentDirectory: URL, now: Date = Date()) -> Bool {
        var pending = preferences.dictionary(forKey: preferenceKey) as? [String: Double] ?? [:]
        let root = attachmentRoot(attachmentDirectory)
        for (path, deadline) in pending where deadline <= now.timeIntervalSince1970 {
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            if canonical.hasPrefix(root), !referencedFiles.contains(canonical), FileManager.default.fileExists(atPath: canonical) {
                do { try FileManager.default.removeItem(atPath: canonical) }
                catch { continue }
            }
            pending.removeValue(forKey: path)
        }
        preferences.set(pending, forKey: preferenceKey)
        return !pending.isEmpty
    }

    private func attachmentRoot(_ directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    }
}
