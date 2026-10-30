import Foundation

/** Durable files and attachment-path repairs used by the observable library store. */
final class ClipHistoryFileStore {
    let historyURL: URL
    private let seenTransferIDsURL: URL

    init(historyURL: URL, seenTransferIDsURL: URL) {
        self.historyURL = historyURL
        self.seenTransferIDsURL = seenTransferIDsURL
    }

    func loadClips() -> [ClipItem] {
        guard let data = try? Data(contentsOf: historyURL),
              let clips = try? JSONDecoder().decode([ClipItem].self, from: data) else { return [] }
        return clips
    }

    @discardableResult
    func saveClips(_ clips: [ClipItem]) -> Bool {
        do {
            try PrivateAppStorage.write(JSONEncoder().encode(clips), to: historyURL)
            return true
        } catch {
            print("Failed to save clips: \(error)")
            return false
        }
    }

    func loadSeenTransferIDs() -> Set<String> {
        guard let data = try? Data(contentsOf: seenTransferIDsURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    func recordSeenTransferAttempt(_ id: String, current: Set<String>) -> Set<String>? {
        guard !id.isEmpty else { return nil }
        guard !current.contains(id) else { return current }
        var updated = current
        updated.insert(id)
        if updated.count > 100_000 { updated = Set(updated.sorted().suffix(80_000)) }
        guard let data = try? JSONEncoder().encode(Array(updated)) else { return nil }
        do {
            try PrivateAppStorage.write(data, to: seenTransferIDsURL)
            return updated
        } catch {
            return nil
        }
    }

    func storageBytes(attachmentDirectory: URL) -> Int64 {
        let historyBytes = Int64((try? historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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
