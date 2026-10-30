import SwiftUI
import AppKit

struct LibrarySidebar: View {
    @ObservedObject var store: ClipStore
    @Binding var filter: LibraryFilter
    @Binding var settings: Bool
    @Binding var selected: Set<UUID>
    let collections: [String]

    private var apps: [KnownApp] {
        Array(Set(store.clips.map(\.sourceApp)))
            .filter { $0 != .generic }
            .sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sidebarGroup("LIBRARY", rows: [
                        ("All Clips", .all, "square.grid.2x2"),
                        ("Pinned", .pinned, "pin"),
                        ("Sent", .sent, "arrow.up.right"),
                        ("Received", .received, "arrow.down.left")
                    ])
                    sidebarGroup("TYPE", rows: [
                        ("Text", .text, "text.alignleft"),
                        ("Images", .images, "photo"),
                        ("Files", .files, "doc")
                    ])
                    if !collections.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            groupLabel("COLLECTIONS")
                            ForEach(collections, id: \.self) { name in row(name, .collection(name), "folder") }
                        }
                    }
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            groupLabel("APPS")
                            ForEach(apps, id: \.self) { app in row(app.rawValue, .app(app), app.iconSymbol) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            Spacer(minLength: 0)
            Button { settings.toggle() } label: {
                Label("Settings & Storage", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .background(.black.opacity(0.12))
    }

    private var brand: some View {
        HStack(spacing: 10) {
            let appIcon = NSImage(named: NSImage.Name("AppIcon")) ??
                NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!
            Image(nsImage: appIcon).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("ClipToMac").font(.system(size: 14, weight: .semibold))
                Text("LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 18)
    }

    private func sidebarGroup(_ title: String, rows: [(String, LibraryFilter, String)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            groupLabel(title)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                row(item.0, item.1, item.2)
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).tracking(1.3)
            .foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 5)
    }

    private func row(_ title: String, _ value: LibraryFilter, _ symbol: String) -> some View {
        Button {
            filter = value
            settings = false
            selected = []
        } label: {
            HStack(spacing: 9) {
                if case .app(let app) = value {
                    SourceAppIcon(app: app, package: "").frame(width: 18, height: 18)
                } else {
                    Image(systemName: symbol).frame(width: 18)
                }
                Text(title)
                Spacer(minLength: 8)
                let count = countFor(value)
                if count > 0 { Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibrarySidebarButtonStyle(selected: filter == value))
        .accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    private func countFor(_ filter: LibraryFilter) -> Int {
        LibraryClipQuery.count(in: store.clips, matching: filter)
    }
}

private struct LibrarySidebarButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}
