import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var store = ClipStore.shared
    @ObservedObject private var transfers = MacTransferService.shared
    @State private var confirmingDelete = false
    @State private var deleteTargets = Set<UUID>()
    @State private var deleteFileChoice = false
    @State private var choosingCollection = false
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selected = Set<UUID>()
    @State private var settings = false
    @State private var collectionName = ""
    @State private var notice: String?
    @State private var selectedDevice: PairedDevice?
    @State private var showFilePicker = false
    private var collections: [String] { Array(Set(store.clips.compactMap(\.collection))).sorted() }
    private var visible: [ClipItem] {
        LibraryClipQuery.visible(in: store.clips, filter: filter, search: search)
    }
    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(store: store, filter: $filter, settings: $settings, selected: $selected, collections: collections)
                .frame(width: 220)
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                LibraryToolbar(
                    search: $search,
                    selected: $selected,
                    selectedDevice: $selectedDevice,
                    settings: $settings,
                    title: title,
                    itemCount: visible.count,
                    visibleIDs: Set(visible.map(\.id)),
                    pairedDevices: store.pairedDevices,
                    onSendClipboard: sendClipboard(to:),
                    onSendSelected: sendSelected(to:),
                    onChooseFile: { device in selectedDevice = device; showFilePicker = true }
                )
                .zIndex(1)
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                Group {
                    if settings {
                        LibrarySettingsView(store: store, onExportBackup: backupExport, onImportBackup: backupImport)
                    } else {
                        contentPane
                    }
                }
                .clipped()
            }
        }
        .font(.system(size: 13))
        .background(ReadableLibraryGlass())
        .tint(Color(white: 0.74))
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { if selectedDevice == nil { selectedDevice = store.pairedDevices.first } }
        .onChange(of: store.pairedDevices) { devices in
            if let current = selectedDevice { selectedDevice = devices.first(where: { $0.token == current.token }) ?? devices.first(where: { $0.id == current.id }) ?? devices.first }
            else { selectedDevice = devices.first }
        }
        .sheet(isPresented: $choosingCollection) { collectionEditor }
        .sheet(isPresented: $confirmingDelete) {
            AttachmentDeleteSheet(count: deleteTargets.count, hasAttachments: store.clips.contains { deleteTargets.contains($0.id) && $0.attachmentPath != nil }, deleteFiles: $deleteFileChoice) {
                for item in store.clips where deleteTargets.contains(item.id) && item.direction == "sent" && item.deliveryState != "delivered" { transfers.cancel(id: item.transferID) }
                store.removeClips(ids: deleteTargets, deleteFiles: deleteFileChoice); selected = []; confirmingDelete = false
            } onCancel: { confirmingDelete = false }
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice { HStack(spacing:10){ Text(notice).font(.system(size:12)); Button { self.notice=nil } label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain) }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.16))).padding(18) }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            Task { @MainActor in
            do { notice = "Preparing file…"; let url = try result.get()[0]; let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; guard let device = selectedDevice else { throw TransferError.invalidDevice }; try await MacTransferService.shared.sendFile(url, to: device); notice = "File queued for \(device.name)." }
            catch { notice = error.localizedDescription }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !providers.contains(where: { $0.hasItemConformingToTypeIdentifier("com.vdx.cliptomac.library-item") }) else { return false }
            guard let provider = providers.first, let device = selectedDevice ?? store.pairedDevices.first else { notice = "Pair a phone before sending a file."; return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                Task { @MainActor in
                    guard let url else { notice = error?.localizedDescription ?? "Could not read the dropped file."; return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { let id = try await MacTransferService.shared.sendFile(url, to: device); _ = store.recordOutbound(text: "", fileURL: url, to: device, transferID: id); notice = "File queued for \(device.name)." }
                    catch { notice = error.localizedDescription }
                }
            }
            return true
        }
    }
    private var title:String { switch filter {case .all:return "All Clips";case .pinned:return "Pinned";case .sent:return "Sent";case .received:return "Received";case .text:return "Text";case .images:return "Images";case .files:return "Files";case .collection(let n):return n;case .app(let a):return a.rawValue} }
    private var contentPane: some View {
        VStack(spacing:0) {
            if !selected.isEmpty { HStack { Text("\(selected.count) selected"); Button("Pin / Unpin"){store.togglePinned(ids:selected)}; Button("Collection…"){ collectionName = ""; choosingCollection = true }; Button("Export"){exportSelection()}; Button("Delete"){requestDelete(selected)}; Spacer(); Menu("Send to"){ForEach(store.pairedDevices){device in Button(device.name){sendSelected(to:device)}}}.disabled(store.pairedDevices.isEmpty) }.buttonStyle(.bordered).controlSize(.small).padding(12) }
            if visible.isEmpty { VStack(spacing:10){ Image(systemName:search.isEmpty ? "doc.on.clipboard":"magnifyingglass").font(.system(size:30,weight:.ultraLight)).foregroundStyle(.secondary); Text(search.isEmpty ? "No clips here yet":"No matches").font(.system(size:17,weight:.medium)); Text("Items explicitly sent between your paired devices appear here.").font(.system(size:12)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(visible) { clip in
                            LibraryClipRow(
                                clip: clip,
                                isSelected: selected.contains(clip.id),
                                selectionMode: !selected.isEmpty,
                                pairedDevices: store.pairedDevices,
                                onToggleSelection: { toggleSelection(clip.id) },
                                onTogglePin: { store.togglePinned(ids: [clip.id]) },
                                onCopyText: { store.copyToClipboard(clip) },
                                onCopyImage: {
                                    notice = store.copyImageToClipboard(clip)
                                        ? "Image copied. Paste with ⌘V."
                                        : "Couldn’t copy image. The file may be missing or unreadable."
                                },
                                onOpenURL: { if let url = URL(string: clip.text) { NSWorkspace.shared.open(url) } },
                                onReveal: {
                                    if let path = clip.attachmentPath {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                    }
                                },
                                onOpenAttachment: {
                                    if let path = clip.attachmentPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                },
                                onSend: { send(clip, to: $0) },
                                onDelete: { requestDelete([clip.id]) }
                            )
                        }
                    }
                    .padding(18)
                }
            }
            transferTray
            if store.undoAvailable { HStack { Text("Clip deleted"); Spacer(); Button("Undo"){store.undoDelete()} }.padding(10).background(.primary.opacity(0.04)) }
        }
    }
    private func requestDelete(_ ids: Set<UUID>) { deleteTargets = ids; deleteFileChoice = store.deleteStoredFilesByDefault; confirmingDelete = true }
    private func toggleSelection(_ id:UUID){ if selected.contains(id){selected.remove(id)}else{selected.insert(id)} }
    private func sendSelected(to device:PairedDevice){ let items=visible.filter{selected.contains($0.id)}; guard !items.isEmpty else{return}; for item in items { send(item,to:device) }; selected=[] }
    private func sendClipboard(to device:PairedDevice){ guard let text=NSPasteboard.general.string(forType:.string),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{notice="There is no text on the Mac clipboard.";return}; do{let id=try MacTransferService.shared.sendText(text,to:device);_ = store.recordOutbound(text:text,to:device,transferID:id);notice="Clipboard sent to \(device.name)."}catch{notice=error.localizedDescription} }
    private func send(_ item:ClipItem,to device:PairedDevice){ Task { @MainActor in do { if item.kind == .text { let id=try MacTransferService.shared.sendText(item.text,to:device); _=store.recordOutbound(text:item.text,to:device,transferID:id) } else if let p=item.attachmentPath { let id=try await MacTransferService.shared.sendFile(URL(fileURLWithPath:p),to:device); _=store.recordOutbound(text:"",fileURL:URL(fileURLWithPath:p),to:device,transferID:id) }; notice="Transfer queued for \(device.name)." } catch { notice=error.localizedDescription } } }
    private func exportSelection(){ let panel=NSSavePanel();panel.nameFieldStringValue="ClipToMac-export.json";panel.begin{ response in guard response == .OK, let url=panel.url else{return}; let items=store.clips.filter{selected.contains($0.id)}; do { try store.exportBackup(to:url,items:items) } catch {notice=error.localizedDescription} } }
    private var collectionEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to collection").font(.system(size: 20, weight: .semibold))
            TextField("Collection name", text: $collectionName).textFieldStyle(.roundedBorder)
            if !collections.isEmpty { Picker("Existing", selection: $collectionName) { Text("Choose…").tag(""); ForEach(collections, id: \.self) { Text($0).tag($0) } } }
            HStack {
                Button("Remove collection") { store.setCollection(nil, ids: selected); choosingCollection = false }
                Spacer()
                Button("Cancel") { choosingCollection = false }
                Button("Save") { store.setCollection(String(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), ids: selected); choosingCollection = false }.disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 410).background(.regularMaterial)
    }
    private var transferTray: some View { TransferPanel() }
    private func backupExport(){let p=NSSavePanel();p.nameFieldStringValue="ClipToMac-backup.json";p.begin{if $0 == .OK,let u=p.url{do{try store.exportBackup(to:u)}catch{notice=error.localizedDescription}}}}
    private func backupImport(){let p=NSOpenPanel();p.canChooseFiles=true;p.allowedContentTypes=[.json];p.begin{if $0 == .OK,let u=p.url{do{try store.importBackup(from:u);notice="Backup imported."}catch{notice=error.localizedDescription}}}}
}

struct SourceAppIcon: View {
    let app: KnownApp
    let package: String
    var body: some View {
        Group {
            if let icon = installedIcon { Image(nsImage:icon).resizable().aspectRatio(contentMode:.fit).padding(2) }
            else if let icon = brandIcon { Image(nsImage:icon).resizable().renderingMode(.template).foregroundStyle(.primary.opacity(0.82)).aspectRatio(contentMode:.fit).padding(7).frame(maxWidth:.infinity,maxHeight:.infinity).background(brandTint.opacity(0.18),in:RoundedRectangle(cornerRadius:7)) }
            else { Image(systemName:app.iconSymbol).font(.system(size:15,weight:.medium)).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity).background(.primary.opacity(0.06),in:RoundedRectangle(cornerRadius:7)) }
        }.clipShape(RoundedRectangle(cornerRadius:7))
    }
    private var installedIcon:NSImage? {
        let names:[KnownApp:String] = [.brave:"Brave Browser",.safari:"Safari",.chrome:"Google Chrome",.firefox:"Firefox",.whatsApp:"WhatsApp",.reddit:"Reddit",.twitter:"X"]
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) { return NSWorkspace.shared.icon(forFile:url.path) }
        if let name=names[app] { let path="/Applications/\(name).app"; if FileManager.default.fileExists(atPath:path) { return NSWorkspace.shared.icon(forFile:path) } }
        return nil
    }
    private var brandIcon: NSImage? {
        let name: String
        switch app { case .brave:name="brave";case .whatsApp:name="whatsapp";case .reddit:name="reddit";case .twitter:name="x";case .instagram:name="instagram";case .youtube:name="youtube";case .telegram:name="telegram";case .chrome:name="googlechrome";default:return nil }
        guard let url=Bundle.main.resourceURL?.appendingPathComponent("BrandIcons/\(name).svg") else{return nil}
        return NSImage(contentsOf:url)
    }
    private var brandTint: Color {
        switch app {case .whatsApp:return .green;case .reddit:return .orange;case .brave:return .orange;case .twitter:return .blue;case .instagram:return .pink;case .youtube:return .red;case .telegram:return .blue;default:return .gray}
    }
    private var bundleID:String { switch app {case .brave:return "com.brave.Browser";case .safari:return "com.apple.Safari";case .chrome:return "com.google.Chrome";case .firefox:return "org.mozilla.firefox";case .whatsApp:return "net.whatsapp.WhatsApp";case .twitter:return "com.atebits.Tweetie2";default:return package} }
}

private struct ReadableLibraryGlass: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View { ZStack { if #available(macOS 26.0,*) { Color.clear.glassEffect(.regular,in:Rectangle()); Rectangle().fill(colorScheme == .dark ? Color.black.opacity(0.16):Color.white.opacity(0.16)) } else { VisualEffectView(material:.sidebar,blendingMode:.behindWindow) } } }
}
