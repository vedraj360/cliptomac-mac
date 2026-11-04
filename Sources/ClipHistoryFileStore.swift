import Foundation

/** Durable files and attachment-path repairs used by the observable library store. */
final class ClipHistoryFileStore {
    private let databaseURL: URL
    private let database: ClipHistoryDatabase?

    init(historyURL: URL, seenTransferIDsURL: URL) {
        databaseURL = historyURL.deletingLastPathComponent().appendingPathComponent("library.sqlite3")
        do {
            database = try ClipHistoryDatabase(url: databaseURL, legacyHistory: historyURL, legacyReceipts: seenTransferIDsURL)
        } catch {
            database = nil
            NSLog("ClipToMac: library database could not be opened or migrated")
        }
    }

    func loadClips() -> [ClipItem] {
        (try? database?.loadClips()) ?? []
    }

    @discardableResult
    func saveClips(_ clips: [ClipItem]) -> Bool {
        guard let database else { return false }
        do {
            try database.save(clips: clips)
            return true
        } catch {
            NSLog("ClipToMac: library database write failed")
            return false
        }
    }

    func loadSeenTransferIDs() -> Set<String> {
        (try? database?.loadReceipts()) ?? []
    }

    func recordSeenTransferAttempt(_ id: String, current: Set<String>, clips: [ClipItem]? = nil) -> Set<String>? {
        guard !id.isEmpty, let database else { return nil }
        guard !current.contains(id) else { return current }
        var updated = current
        updated.insert(id)
        if updated.count > 100_000 { updated = Set(updated.sorted().suffix(80_000)) }
        do {
            try database.save(clips: clips, receipts: updated)
            return updated
        } catch {
            NSLog("ClipToMac: transfer receipt write failed")
            return nil
        }
    }

    func storageBytes(attachmentDirectory: URL) -> Int64 {
        let historyBytes = Int64((try? databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard let enumerator = FileManager.default.enumerator(at: attachmentDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return historyBytes
        }
        var attachmentBytes: Int64 = 0
        for case let file as URL in enumerator {
            attachmentBytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return historyBytes + attachmentBytes
    }

    func repairAttachmentExtensions(in clips: [ClipItem], attachmentDirectory: URL) -> [ClipItem] {
        let root = attachmentDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var repaired = clips
        var moves: [(source: URL, target: URL)] = []

        for index in repaired.indices where repaired[index].direction == "received" {
            guard let path = repaired[index].attachmentPath else { continue }
            let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard source.path.hasPrefix(root), source.pathExtension.isEmpty,
                  FileManager.default.fileExists(atPath: source.path),
                  let ext = AttachmentFilename.fileExtension(name: repaired[index].attachmentName ?? "", mimeType: repaired[index].mimeType) else { continue }
            let target = source.appendingPathExtension(ext)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            do {
                try FileManager.default.moveItem(at: source, to: target)
                moves.append((source, target))
                for reference in repaired.indices where repaired[reference].attachmentPath == path {
                    repaired[reference].attachmentPath = target.path
                }
            } catch {
                print("Attachment filename repair deferred")
            }
        }

        guard !moves.isEmpty else { return repaired }
        guard saveClips(repaired) else {
            for move in moves.reversed() { try? FileManager.default.moveItem(at: move.target, to: move.source) }
            return clips
        }
        return repaired
    }
}
