import AppKit

/// Write image data rather than a filename or Finder reference.
enum AttachmentClipboard {
    static func copyImage(at url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url), image.isValid else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
