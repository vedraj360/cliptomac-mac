import Foundation
import UniformTypeIdentifiers

/// Keep extensions outside the truncation budget so Finder can identify received files.
enum AttachmentFilename {
    static func fileExtension(name: String, mimeType: String?) -> String? {
        let existing = (name as NSString).pathExtension
        if existing.range(of: "^[A-Za-z0-9]{1,16}$", options: .regularExpression) != nil { return existing }
        let mime = mimeType?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased()
        return mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
    }

    static func safeName(_ name: String, mimeType: String?) -> String {
        let clean = String(name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) ? "_" : Character(scalar)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = fileExtension(name: clean, mimeType: mimeType)
        let stem = (clean as NSString).pathExtension.isEmpty ? clean : (clean as NSString).deletingPathExtension
        let suffix = ext.map { "." + $0 } ?? ""
        var bounded = ""
        for char in stem {
            if bounded.utf8.count + String(char).utf8.count + suffix.utf8.count > 180 { break }
            bounded.append(char)
        }
        return (bounded.isEmpty || bounded == "." || bounded == ".." ? "attachment" : bounded) + suffix
    }
}
