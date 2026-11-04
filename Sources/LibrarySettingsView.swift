import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySettingsView: View {
  @ObservedObject var store: ClipStore
  let onExportBackup: () -> Void
  let onImportBackup: () -> Void
  @State private var confirmClear = false
  @State private var deleteClearFiles = false
  @State private var unpairTarget: PairedDevice?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        storageSection
        deletionSection
        backupSection
        shortcutSection
        PreferencesScreen(
          store: store, confirmClear: $confirmClear, deleteClearFiles: $deleteClearFiles,
          unpairTarget: $unpairTarget, embedded: true
        )
      }
      .padding(22)
    }
    .sheet(isPresented: $confirmClear) {
      AttachmentDeleteSheet(
        count: store.clips.count,
        hasAttachments: store.clips.contains { $0.attachmentPath != nil },
        deleteFiles: $deleteClearFiles
      ) {
        for item in store.clips where item.direction == "sent" && item.deliveryState != "delivered" {
          MacTransferService.shared.cancel(id: item.transferID)
        }
        store.removeClips(ids: Set(store.clips.map(\.id)), deleteFiles: deleteClearFiles)
        confirmClear = false
      } onCancel: {
        confirmClear = false
      }
    }
    .alert("Unpair phone?", isPresented: Binding(
      get: { unpairTarget != nil }, set: { if !$0 { unpairTarget = nil } }
    ), presenting: unpairTarget) { device in
      Button("Unpair", role: .destructive) { store.unpairDevice(id: device.id) }
      Button("Cancel", role: .cancel) {}
    } message: { device in
      Text("You can pair \(device.name) again from its ClipToMac app.")
    }
  }

  private var storageSection: some View {
    settingsSection("STORAGE") {
      Text(store.storageDirectory.path)
        .font(AppTypography.font(size: 11)).textSelection(.enabled)
      Text(
        "Using \(ByteCountFormatter.string(fromByteCount: store.storageBytes, countStyle: .file))"
      )
      .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      HStack {
        Button("Open Finder") { NSWorkspace.shared.open(store.storageDirectory) }
        Button("Choose attachment folder", action: chooseAttachmentFolder)
      }
      Text("Attachments: \(store.attachmentDirectory.path)")
        .font(AppTypography.font(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
    }
  }

  private var deletionSection: some View {
    settingsSection("DELETION") {
      Toggle(
        "Delete stored attachments with history by default", isOn: $store.deleteStoredFilesByDefault
      )
      Text(
        "Only ClipToMac’s local copies are removed after Undo expires. Original files and the phone’s copies are kept."
      )
      .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
    }
  }

  private var backupSection: some View {
    settingsSection("BACKUP") {
      HStack {
        Button("Export backup…", action: onExportBackup)
        Button("Import backup…", action: onImportBackup)
      }
      Text(
        "Backups contain library entries and attachment files. Paired device credentials are never included."
      )
      .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
    }
  }

  private var shortcutSection: some View {
    settingsSection("GLOBAL SHORTCUT") {
      HStack {
        Text("Show / hide library")
        Spacer()
        Picker("Modifiers", selection: $store.shortcutModifiers) {
          Text("⌘⌥").tag(UInt32(0x900))
          Text("⌘⇧").tag(UInt32(0x300))
          Text("⌃⌥").tag(UInt32(0x1800))
        }
        .labelsHidden().frame(width: 90)
        Picker("Shortcut key", selection: $store.shortcutKeyCode) {
          Text("V").tag(UInt32(9))
          Text("L").tag(UInt32(37))
          Text("Space").tag(UInt32(49))
          Text("C").tag(UInt32(8))
        }
        .labelsHidden().frame(width: 100)
      }
      Text("Registered as a system hotkey; ClipToMac does not monitor keystrokes.")
        .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func settingsSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(AppTypography.heading(size: 10)).tracking(1.4).foregroundStyle(
        .secondary)
      content()
    }
    .padding(15)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
  }

  private func chooseAttachmentFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in store.setAttachmentDirectory(url) }
    }
  }
}
