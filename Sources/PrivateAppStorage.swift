import Foundation
import Darwin

/// Apply only to app-owned locations, never to a user-selected export folder.
enum PrivateAppStorage {
    static func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // Repair files produced by older builds without traversing symlinks.
        if let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            for case let url as URL in entries {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if info.isSymbolicLink == true { entries.skipDescendants(); continue }
                try FileManager.default.setAttributes([.posixPermissions: info.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: url.path)
            }
        }
    }

    static func write(_ data: Data, to url: URL) throws {
        // Create with owner-only permissions from the first byte, including atomic staging.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".private-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var closed = false
        defer { if !closed { close(fd) }; try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        close(fd); closed = true
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
}
