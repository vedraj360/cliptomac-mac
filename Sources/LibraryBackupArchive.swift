import Foundation

private struct ClipBackup: Codable {
    let formatVersion: Int
    let clips: [ClipItem]
    let attachments: [String: Data]
}

struct PreparedLibraryImport {
    let clips: [ClipItem]
    let createdFiles: [URL]
}

/** Owns the versioned JSON archive format and staging of imported attachment bytes. */
enum LibraryBackupArchive {
    private static let maximumImportBytes = 150_000_000
    private static let maximumAttachmentBytes = 100_000_000
    private static let maximumSingleAttachmentBytes = 25_000_000

    static func export(_ clips: [ClipItem], to url: URL) throws {
        var attachments: [String: Data] = [:]
        var totalBytes = 0
        for clip in clips {
            guard let path = clip.attachmentPath else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard bytes.count <= maximumSingleAttachmentBytes else {
                throw archiveError(2, "An attachment exceeds the 25 MB backup limit.")
            }
            totalBytes += bytes.count
            guard totalBytes <= maximumAttachmentBytes else {
                throw archiveError(3, "Attachments exceed the 100 MB backup limit.")
            }
            attachments[clip.id.uuidString] = bytes
        }
        let backup = ClipBackup(formatVersion: 1, clips: clips, attachments: attachments)
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
    }

    static func prepareImport(from url: URL, existingIDs: Set<UUID>, attachmentDirectory: URL) throws -> PreparedLibraryImport {
        let data = try Data(contentsOf: url)
        guard data.count <= maximumImportBytes else {
            throw archiveError(1, "Backup exceeds the 150 MB import limit.")
        }

        let imported: [ClipItem]
        let attachments: [String: Data]
        if let backup = try? JSONDecoder().decode(ClipBackup.self, from: data), backup.formatVersion == 1 {
            imported = backup.clips
            attachments = backup.attachments
        } else {
            imported = try JSONDecoder().decode([ClipItem].self, from: data)
            attachments = [:]
        }
        guard imported.count <= 100_000,
              imported.allSatisfy({ $0.text.utf8.count <= 1_000_000 && $0.transferID.utf8.count <= 512 }) else {
            throw archiveError(1, "Backup exceeds supported limits.")
        }
        let attachmentBytes = attachments.values.reduce(0) { $0 + $1.count }
        guard attachmentBytes <= maximumAttachmentBytes,
              attachments.values.allSatisfy({ $0.count <= maximumSingleAttachmentBytes }) else {
            throw archiveError(1, "Backup attachments exceed supported limits.")
        }

        var createdFiles: [URL] = []
        do {
            var valid: [ClipItem] = []
            var known = existingIDs
            for var item in imported {
                guard known.insert(item.id).inserted else { continue }
                if let bytes = attachments[item.id.uuidString] {
                    try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
                    let suppliedName = item.attachmentName.map { URL(fileURLWithPath: $0).lastPathComponent }
                    let safeName = suppliedName.flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
                    let target = attachmentDirectory.appendingPathComponent(UUID().uuidString + "-" + safeName)
                    try bytes.write(to: target, options: .atomic)
                    createdFiles.append(target)
                    item.attachmentPath = target.path
                } else {
                    item.attachmentPath = nil
                }
                valid.append(item)
            }
            return PreparedLibraryImport(clips: valid, createdFiles: createdFiles)
        } catch {
            removeFiles(createdFiles)
            throw error
        }
    }

    static func discard(_ prepared: PreparedLibraryImport) {
        removeFiles(prepared.createdFiles)
    }

    private static func removeFiles(_ files: [URL]) {
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private static func archiveError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "ClipToMac", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
