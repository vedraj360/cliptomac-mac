import SwiftUI

struct LibraryToolbar: View {
  @Binding var search: String
  @Binding var selected: Set<UUID>
  @Binding var selectedDevice: PairedDevice?
  @Binding var settings: Bool

  let title: String
  let itemCount: Int
  let visibleIDs: Set<UUID>
  let pairedDevices: [PairedDevice]
  let onSendClipboard: (PairedDevice) -> Void
  let onSendSelected: (PairedDevice) -> Void
  let onChooseFile: (PairedDevice) -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(settings ? "Settings & Storage" : title)
          .font(.system(size: 22, weight: .semibold))
        Text(settings ? "LOCAL LIBRARY" : "\(itemCount) items")
          .font(.system(size: 9, weight: .semibold))
          .tracking(1.2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if settings {
        Button("Done") { settings = false }
          .buttonStyle(.bordered)
      } else {
        searchField
        selectionButton
        sendClipboardMenu
        phonePicker
        sendSelectedMenu
        chooseFileMenu
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity)
    .background(headerBackground)
    .overlay(alignment: .bottom) {
      Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
    }
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Search", text: $search)
        .textFieldStyle(.plain)
        .frame(width: 150)
    }
    .padding(8)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
  }

  private var selectionButton: some View {
    Button {
      selected = selected.isEmpty ? visibleIDs : []
    } label: {
      Label(selected.isEmpty ? "Select" : "Done", systemImage: "checkmark.circle")
    }
    .buttonStyle(.bordered)
  }

  private var sendClipboardMenu: some View {
    Menu {
      ForEach(pairedDevices) { device in
        Button("Send clipboard to \(device.name)") { onSendClipboard(device) }
      }
    } label: {
      Label("Send Clipboard", systemImage: "paperplane.fill")
    }
    .menuStyle(.borderlessButton)
    .disabled(pairedDevices.isEmpty)
  }

  private var phonePicker: some View {
    Menu {
      ForEach(pairedDevices) { device in
        Button(device.name) { selectedDevice = device }
      }
    } label: {
      Image(systemName: "iphone")
    }
    .help("Drop files to this phone: \(selectedDevice?.name ?? "Choose phone")")
    .menuStyle(.borderlessButton)
    .disabled(pairedDevices.isEmpty)
  }

  private var sendSelectedMenu: some View {
    Menu {
      ForEach(pairedDevices) { device in
        Button(device.name) { onSendSelected(device) }
      }
    } label: {
      Image(systemName: "paperplane")
    }
    .disabled(selected.isEmpty || pairedDevices.isEmpty)
    .help("Send selected clips to a paired phone")
    .menuStyle(.borderlessButton)
  }

  private var chooseFileMenu: some View {
    Menu {
      ForEach(pairedDevices) { device in
        Button("Choose file for \(device.name)") { onChooseFile(device) }
      }
    } label: {
      Image(systemName: "plus")
    }
    .help("Choose a file to send to a phone")
    .menuStyle(.borderlessButton)
    .disabled(pairedDevices.isEmpty)
  }

  @ViewBuilder
  private var headerBackground: some View {
    if colorScheme == .dark {
      Color(red: 0.10, green: 0.115, blue: 0.13)
    } else {
      Color(nsColor: .windowBackgroundColor)
    }
  }

  @Environment(\.colorScheme) private var colorScheme
}
