import Foundation

enum LibraryFilter: Hashable {
    case all, pinned, sent, received, text, images, files
    case collection(String)
    case app(KnownApp)
}

enum LibraryClipQuery {
    static func visible(in clips: [ClipItem], filter: LibraryFilter, search: String) -> [ClipItem] {
        clips
            .filter { matches($0, filter: filter) && matchesSearch($0, search: search) }
            .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
    }

    static func count(in clips: [ClipItem], matching filter: LibraryFilter) -> Int {
        clips.reduce(into: 0) { count, clip in
            if matches(clip, filter: filter) { count += 1 }
        }
    }

    private static func matches(_ clip: ClipItem, filter: LibraryFilter) -> Bool {
        switch filter {
        case .all: true
        case .pinned: clip.isPinned
        case .sent: clip.direction == "sent"
        case .received: clip.direction != "sent"
        case .text: clip.kind == .text
        case .images: clip.kind == .image
        case .files: clip.kind == .file
        case .collection(let name): clip.collection == name
        case .app(let app): clip.sourceApp == app
        }
    }

    private static func matchesSearch(_ clip: ClipItem, search: String) -> Bool {
        search.isEmpty
            || clip.text.localizedCaseInsensitiveContains(search)
            || clip.appName.localizedCaseInsensitiveContains(search)
            || (clip.attachmentName?.localizedCaseInsensitiveContains(search) ?? false)
    }
}
