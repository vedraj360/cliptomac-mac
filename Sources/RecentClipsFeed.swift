import AppKit
import SwiftUI

struct RecentClipsFeed: View {
  @ObservedObject var store: ClipStore
  @Binding var search: String
  @Binding var selectedApp: KnownApp?
  @Environment(\.colorScheme) private var colorScheme
  @State private var copiedID: UUID?
  @State private var copyErrorID: UUID?

  private var filtered: [ClipItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let items =
      query.isEmpty
      ? store.clips
      : store.clips.filter {
        $0.text.localizedCaseInsensitiveContains(query)
          || $0.appName.localizedCaseInsensitiveContains(query)
      }
    return items.filter { selectedApp == nil || $0.sourceApp == selectedApp }
      .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
  }

  var body: some View {
    VStack(spacing: 0) {
      searchField
      appFilters
      feedHeading

      if filtered.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(spacing: 9) {
            ForEach(filtered) { clip in clipCard(clip) }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 16)
        }
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search clips or apps", text: $search)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(11)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
    .padding(.horizontal, 20)
    .padding(.top, 16)
  }

  @ViewBuilder
  private var appFilters: some View {
    if !store.clips.isEmpty {
      HStack(spacing: 6) {
        Button("Recent") { selectedApp = nil }.buttonStyle(.bordered).controlSize(.small)
        ForEach(
          Array(Set(store.clips.map(\.sourceApp))).filter { $0 != .generic }.sorted {
            $0.rawValue < $1.rawValue
          }, id: \.self
        ) { app in
          Button(app.rawValue) { selectedApp = app }.buttonStyle(.bordered).controlSize(.small)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var feedHeading: some View {
    HStack {
      Text("RECEIVED").font(.system(size: 9, weight: .semibold)).tracking(1.5)
      Spacer()
      Text("\(filtered.count) \(filtered.count == 1 ? "clip" : "clips")").font(.system(size: 11))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 21)
    .padding(.top, 18)
    .padding(.bottom, 10)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
        .font(.system(size: 30, weight: .ultraLight))
        .foregroundStyle(.secondary)
      Text(search.isEmpty ? "Ready for your next idea." : "No matching clips")
        .font(.system(size: 16, weight: .medium))
      Text(
        search.isEmpty
          ? "Copy text on your phone, then tap\nSend to Mac in the top overlay."
          : "Try another word or app name."
      )
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .lineSpacing(4)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.bottom, 24)
  }

  private func clipCard(_ clip: ClipItem) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 7) {
        SourceAppIcon(app: clip.sourceApp, package: clip.packageName).frame(width: 22, height: 22)
        Text(clip.appName).font(.system(size: 11, weight: .medium))
        Spacer()
        Text(clip.relativeTime).font(.system(size: 10)).foregroundStyle(.secondary).help(
          clip.exactTime)
      }
      Text(clip.kind == .text ? clip.text : (clip.attachmentName ?? "Attachment"))
        .font(.system(size: 13))
        .lineSpacing(3)
        .lineLimit(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 14) {
        if clip.kind == .text || clip.kind == .image {
          Button {
            copy(clip)
          } label: {
            Label(
              copyErrorID == clip.id
                ? "Couldn’t copy"
                : (copiedID == clip.id ? "Copied" : (clip.kind == .image ? "Copy image" : "Copy")),
              systemImage: copiedID == clip.id ? "checkmark" : "doc.on.doc")
          }
          .foregroundStyle(
            copyErrorID == clip.id
              ? Color.orange : (copiedID == clip.id ? Color.green : Color.primary))
        }
        if clip.attachmentPath != nil {
          Button {
            reveal(clip)
          } label: {
            Label("Reveal", systemImage: "folder")
          }
        }
        if clip.isURL,
          let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Label("Open", systemImage: "arrow.up.right")
          }
        }
        Spacer()
        Button {
          withAnimation { store.removeClips(ids: [clip.id]) }
        } label: {
          Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .help("Delete clip")
        .accessibilityLabel("Delete clip")
      }
      .buttonStyle(.plain)
      .font(.system(size: 11, weight: .medium))
    }
    .padding(14)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.16))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.075), lineWidth: 0.7))
  }

  private func copy(_ clip: ClipItem) {
    let success: Bool
    if clip.kind == .image {
      success = store.copyImageToClipboard(clip)
    } else {
      store.copyToClipboard(clip)
      success = true
    }
    if success {
      copiedID = clip.id
      copyErrorID = nil
    } else {
      copyErrorID = clip.id
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      if copiedID == clip.id { copiedID = nil }
      if copyErrorID == clip.id { copyErrorID = nil }
    }
  }

  private func reveal(_ clip: ClipItem) {
    guard let path = clip.attachmentPath else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}
