import AppKit
import SwiftUI

struct LibraryClipRow: View {
  let clip: ClipItem
  let isSelected: Bool
  let selectionMode: Bool
  let pairedDevices: [PairedDevice]
  let onToggleSelection: () -> Void
  let onTogglePin: () -> Void
  let onCopyText: () -> Void
  let onCopyImage: () -> Void
  let onOpenURL: () -> Void
  let onReveal: () -> Void
  let onOpenAttachment: () -> Void
  let onSend: (PairedDevice) -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      if selectionMode {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? .primary : .secondary)
          .padding(.top, 3)
      }

      SourceAppIcon(app: clip.sourceApp, package: clip.packageName)
        .frame(width: 30, height: 30)

      VStack(alignment: .leading, spacing: 8) {
        metadata
        content
        actions
      }
    }
    .padding(14)
    .background(.primary.opacity(isSelected ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
    .contentShape(Rectangle())
    .onTapGesture { if selectionMode { onToggleSelection() } }
    .onDrag(dragProvider)
  }

  private var metadata: some View {
    HStack(spacing: 7) {
      Text(clip.appName).font(.system(size: 12, weight: .medium))
      Text(clip.direction.uppercased())
        .font(.system(size: 8, weight: .semibold))
        .tracking(1)
        .foregroundStyle(.secondary)
      Spacer()
      if clip.repeatCount > 1 {
        Text("×\(clip.repeatCount)")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      Text(clip.relativeTime).font(.system(size: 10)).foregroundStyle(.secondary)
      Button(action: onTogglePin) {
        Image(systemName: clip.isPinned ? "pin.fill" : "pin")
          .foregroundStyle(clip.isPinned ? .primary : .secondary)
      }
      .buttonStyle(.plain)
      .help(clip.isPinned ? "Unpin clip" : "Pin clip")
    }
  }

  @ViewBuilder
  private var content: some View {
    if clip.kind == .image, let path = clip.attachmentPath,
      let image = NSImage(contentsOfFile: path)
    {
      Image(nsImage: image)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxHeight: 160)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    if clip.kind == .text {
      Text(clip.text)
        .font(.system(size: 13))
        .lineSpacing(3)
        .lineLimit(4)
        .textSelection(.enabled)
    } else {
      Label(
        clip.attachmentName ?? clip.kind.rawValue,
        systemImage: clip.kind == .image ? "photo" : "doc"
      )
      .font(.system(size: 13))
      if let path = clip.attachmentPath {
        Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 14) {
      if clip.kind == .text {
        Button("Copy", action: onCopyText).buttonStyle(.plain)
      }
      if clip.kind == .image {
        Button("Copy image", action: onCopyImage).buttonStyle(.plain)
      }
      if clip.isURL {
        Button("Open", action: onOpenURL).buttonStyle(.plain)
      }
      if clip.attachmentPath != nil {
        Button("Reveal", action: onReveal).buttonStyle(.plain)
        Button("Open", action: onOpenAttachment).buttonStyle(.plain)
      }
      Spacer()
      if clip.direction != "sent", !pairedDevices.isEmpty {
        Menu {
          ForEach(pairedDevices) { device in
            Button(device.name) { onSend(device) }
          }
        } label: {
          Image(systemName: "paperplane")
        }
        .menuStyle(.borderlessButton)
        .help("Send to phone")
      }
      Button(action: onDelete) {
        Image(systemName: "trash").foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Delete on this Mac")
    }
    .font(.system(size: 11, weight: .medium))
  }

  private func dragProvider() -> NSItemProvider {
    let provider: NSItemProvider
    if let path = clip.attachmentPath {
      provider = NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
    } else {
      provider = NSItemProvider(object: clip.text as NSString)
    }
    provider.registerDataRepresentation(
      forTypeIdentifier: "com.vdx.cliptomac.library-item", visibility: .all
    ) { completion in
      completion(Data(clip.id.uuidString.utf8), nil)
      return nil
    }
    return provider
  }
}
