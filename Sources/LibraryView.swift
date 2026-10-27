import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum LibraryFilter: Hashable { case all, pinned, sent, received, text, images, files, collection(String), app(KnownApp) }

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
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
        let matching = store.clips.filter { clip in
            let passes: Bool
            switch filter { case .all: passes = true; case .pinned: passes = clip.isPinned; case .sent: passes = clip.direction == "sent"; case .received: passes = clip.direction != "sent"; case .text: passes = clip.kind == .text; case .images: passes = clip.kind == .image; case .files: passes = clip.kind == .file; case .collection(let n): passes = clip.collection == n; case .app(let a): passes = clip.sourceApp == a }
            return passes && (search.isEmpty || clip.text.localizedCaseInsensitiveContains(search) || clip.appName.localizedCaseInsensitiveContains(search) || (clip.attachmentName?.localizedCaseInsensitiveContains(search) ?? false))
        }
        return matching.sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 220)
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                topBar.zIndex(1)
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                Group { if settings { settingsPane } else { contentPane } }.clipped()
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
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { Image(nsImage: NSImage(named: NSImage.Name("AppIcon")) ?? NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!).resizable().frame(width: 24,height:24); VStack(alignment:.leading,spacing:2){ Text("ClipToMac").font(.system(size:14,weight:.semibold)); Text("LIBRARY").font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary) } }.padding(.horizontal,17).padding(.vertical,18)
            ScrollView { VStack(alignment:.leading,spacing:16) {
                sidebarGroup("LIBRARY", rows: [("All Clips",.all,"square.grid.2x2"),("Pinned",.pinned,"pin"),("Sent",.sent,"arrow.up.right"),("Received",.received,"arrow.down.left")])
                sidebarGroup("TYPE", rows: [("Text",.text,"text.alignleft"),("Images",.images,"photo"),("Files",.files,"doc")])
                if !collections.isEmpty { VStack(alignment:.leading,spacing:5){ label("COLLECTIONS"); ForEach(collections,id:\.self){ row($0,.collection($0),"folder") } } }
                let apps = Array(Set(store.clips.map(\.sourceApp))).filter { $0 != .generic }.sorted { $0.rawValue < $1.rawValue }
                if !apps.isEmpty { VStack(alignment:.leading,spacing:5){ label("APPS"); ForEach(apps,id:\.self){ row($0.rawValue,.app($0),$0.iconSymbol) } } }
            }.padding(.horizontal,10).padding(.vertical,8) }
            Spacer(minLength:0)
            Button { settings.toggle() } label: { Label("Settings & Storage",systemImage:"gearshape") }.buttonStyle(.plain).padding(14)
        }.background(.black.opacity(0.12))
    }
    private func sidebarGroup(_ title:String, rows:[(String,LibraryFilter,String)]) -> some View { VStack(alignment:.leading,spacing:5){ label(title); ForEach(Array(rows.enumerated()),id:\.offset){ pair in let item=pair.element; row(item.0,item.1,item.2) } } }
    private func label(_ text:String)->some View { Text(text).font(.system(size:9,weight:.semibold)).tracking(1.3).foregroundStyle(.secondary).padding(.horizontal,9).padding(.top,5) }
    private func row(_ title: String, _ value: LibraryFilter, _ symbol: String) -> some View {
        Button { filter = value; settings = false; selected = [] } label: {
            HStack(spacing: 9) {
                if case .app(let app) = value { SourceAppIcon(app: app, package: "").frame(width: 18, height: 18) }
                else { Image(systemName: symbol).frame(width: 18) }
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
    private func countFor(_ f:LibraryFilter)->Int { switch f {case .all:return store.clips.count;case .pinned:return store.clips.filter(\.isPinned).count;case .sent:return store.clips.filter{$0.direction=="sent"}.count;case .received:return store.clips.filter{$0.direction != "sent"}.count;case .text:return store.clips.filter{$0.kind == .text}.count;case .images:return store.clips.filter{$0.kind == .image}.count;case .files:return store.clips.filter{$0.kind == .file}.count;case .collection(let n):return store.clips.filter{$0.collection==n}.count;case .app(let a):return store.clips.filter{$0.sourceApp==a}.count} }
    private var topBar: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:3){ Text(settings ? "Settings & Storage" : title).font(.system(size:22,weight:.semibold)); Text(settings ? "LOCAL LIBRARY" : "\(visible.count) items").font(.system(size:9,weight:.semibold)).tracking(1.2).foregroundStyle(.secondary) }
            Spacer()
            if !settings {
                HStack(spacing:7){ Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("Search",text:$search).textFieldStyle(.plain).frame(width:150) }.padding(8).background(.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:7))
                Button { selected = selected.isEmpty ? Set(visible.map(\.id)) : [] } label:{ Label(selected.isEmpty ? "Select" : "Done",systemImage:"checkmark.circle") }.buttonStyle(.bordered)
                Menu { ForEach(store.pairedDevices) { device in Button("Send clipboard to \(device.name)") { sendClipboard(to:device) } } } label: { Label("Send Clipboard",systemImage:"paperplane.fill") }.menuStyle(.borderlessButton).disabled(store.pairedDevices.isEmpty)
                Menu { ForEach(store.pairedDevices) { device in Button(device.name) { selectedDevice=device } } } label: { Image(systemName:"iphone") }.help("Drop files to this phone: \(selectedDevice?.name ?? "Choose phone")").menuStyle(.borderlessButton).disabled(store.pairedDevices.isEmpty)
                Menu { ForEach(store.pairedDevices) { device in Button(device.name) { sendSelected(to: device) } } } label: { Image(systemName: "paperplane") }.disabled(selected.isEmpty || store.pairedDevices.isEmpty).help("Send selected clips to a paired phone").menuStyle(.borderlessButton)
                Menu { ForEach(store.pairedDevices) { device in Button("Choose file for \(device.name)") { selectedDevice=device; showFilePicker=true } } } label:{ Image(systemName:"plus") }.help("Choose a file to send to a phone").menuStyle(.borderlessButton).disabled(store.pairedDevices.isEmpty)
            } else { Button("Done"){settings=false}.buttonStyle(.bordered) }
        }
        .padding(.horizontal,22).padding(.vertical,16)
        .frame(maxWidth: .infinity)
        .background(colorScheme == .dark ? Color(red: 0.10, green: 0.115, blue: 0.13) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 1) }
    }
    private var title:String { switch filter {case .all:return "All Clips";case .pinned:return "Pinned";case .sent:return "Sent";case .received:return "Received";case .text:return "Text";case .images:return "Images";case .files:return "Files";case .collection(let n):return n;case .app(let a):return a.rawValue} }
    private var contentPane: some View {
        VStack(spacing:0) {
            if !selected.isEmpty { HStack { Text("\(selected.count) selected"); Button("Pin / Unpin"){store.togglePinned(ids:selected)}; Button("Collection…"){ collectionName = ""; choosingCollection = true }; Button("Export"){exportSelection()}; Button("Delete"){requestDelete(selected)}; Spacer(); Menu("Send to"){ForEach(store.pairedDevices){device in Button(device.name){sendSelected(to:device)}}}.disabled(store.pairedDevices.isEmpty) }.buttonStyle(.bordered).controlSize(.small).padding(12) }
            if visible.isEmpty { VStack(spacing:10){ Image(systemName:search.isEmpty ? "doc.on.clipboard":"magnifyingglass").font(.system(size:30,weight:.ultraLight)).foregroundStyle(.secondary); Text(search.isEmpty ? "No clips here yet":"No matches").font(.system(size:17,weight:.medium)); Text("Items explicitly sent between your paired devices appear here.").font(.system(size:12)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,maxHeight:.infinity) }
            else { ScrollView { LazyVStack(spacing:9){ ForEach(visible){ clip in clipRow(clip) } }.padding(18) } }
            transferTray
            if store.undoAvailable { HStack { Text("Clip deleted"); Spacer(); Button("Undo"){store.undoDelete()} }.padding(10).background(.primary.opacity(0.04)) }
        }
    }
    private func clipRow(_ clip:ClipItem)->some View {
        HStack(alignment:.top,spacing:12) {
            if !selected.isEmpty { Image(systemName:selected.contains(clip.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(clip.id) ? .primary : .secondary).padding(.top,3) }
            SourceAppIcon(app:clip.sourceApp,package:clip.packageName).frame(width:30,height:30)
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:7){ Text(clip.appName).font(.system(size:12,weight:.medium)); Text(clip.direction.uppercased()).font(.system(size:8,weight:.semibold)).tracking(1).foregroundStyle(.secondary); Spacer(); if clip.repeatCount>1 { Text("×\(clip.repeatCount)").font(.system(size:10,weight:.medium)).foregroundStyle(.secondary) }; Text(clip.relativeTime).font(.system(size:10)).foregroundStyle(.secondary); Button { store.togglePinned(ids:[clip.id]) } label:{ Image(systemName:clip.isPinned ? "pin.fill":"pin").foregroundStyle(clip.isPinned ? .primary : .secondary) }.buttonStyle(.plain) }
                if clip.kind == .image, let path = clip.attachmentPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 6)) }
                if clip.kind == .text { Text(clip.text).font(.system(size:13)).lineSpacing(3).lineLimit(4).textSelection(.enabled) } else { Label(clip.attachmentName ?? clip.kind.rawValue,systemImage:clip.kind == .image ? "photo":"doc").font(.system(size:13)); if let p=clip.attachmentPath { Text(p).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1) } }
                HStack(spacing:14) {
                    if clip.kind == .text { Button("Copy"){ store.copyToClipboard(clip) }.buttonStyle(.plain) }
                    if clip.isURL, let url=URL(string:clip.text) { Button("Open"){ NSWorkspace.shared.open(url) }.buttonStyle(.plain) }
                    if let path=clip.attachmentPath { Button("Reveal"){ NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)]) }.buttonStyle(.plain); Button("Open"){ NSWorkspace.shared.open(URL(fileURLWithPath:path)) }.buttonStyle(.plain) }
                    Spacer()
                    if clip.direction != "sent", !store.pairedDevices.isEmpty { Menu { ForEach(store.pairedDevices){ d in Button(d.name){ send(clip,to:d) } } } label:{ Image(systemName:"paperplane") }.menuStyle(.borderlessButton).help("Send to phone") }
                    Button { requestDelete([clip.id]) } label:{ Image(systemName:"trash").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Delete on this Mac")
                }.font(.system(size:11,weight:.medium))
            }
        }.padding(14).background(.primary.opacity(selected.contains(clip.id) ? 0.075 : 0.035),in:RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.primary.opacity(0.07)))
            .contentShape(Rectangle()).onTapGesture { if !selected.isEmpty { toggleSelection(clip.id) } }
            .onDrag {
                let provider: NSItemProvider
                if let path = clip.attachmentPath { provider = NSItemProvider(object: URL(fileURLWithPath: path) as NSURL) }
                else { provider = NSItemProvider(object: clip.text as NSString) }
                provider.registerDataRepresentation(forTypeIdentifier: "com.vdx.cliptomac.library-item", visibility: .all) { completion in completion(Data(clip.id.uuidString.utf8), nil); return nil }
                return provider
            }
    }
    private func requestDelete(_ ids: Set<UUID>) { deleteTargets = ids; deleteFileChoice = store.deleteStoredFilesByDefault; confirmingDelete = true }
    private func toggleSelection(_ id:UUID){ if selected.contains(id){selected.remove(id)}else{selected.insert(id)} }
    private func sendSelected(to device:PairedDevice){ let items=visible.filter{selected.contains($0.id)}; guard !items.isEmpty else{return}; for item in items { send(item,to:device) }; selected=[] }
    private func sendClipboard(to device:PairedDevice){ guard let text=NSPasteboard.general.string(forType:.string),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{notice="There is no text on the Mac clipboard.";return}; do{let id=try MacTransferService.shared.sendText(text,to:device);_ = store.recordOutbound(text:text,to:device,transferID:id);notice="Clipboard sent to \(device.name)."}catch{notice=error.localizedDescription} }
    private func send(_ item:ClipItem,to device:PairedDevice){ Task { @MainActor in do { if item.kind == .text { let id=try MacTransferService.shared.sendText(item.text,to:device); _=store.recordOutbound(text:item.text,to:device,transferID:id) } else if let p=item.attachmentPath { let id=try await MacTransferService.shared.sendFile(URL(fileURLWithPath:p),to:device); _=store.recordOutbound(text:"",fileURL:URL(fileURLWithPath:p),to:device,transferID:id) }; notice="Transfer queued for \(device.name)." } catch { notice=error.localizedDescription } } }
    private func exportSelection(){ let panel=NSSavePanel();panel.nameFieldStringValue="ClipToMac-export.json";panel.begin{ response in guard response == .OK, let url=panel.url else{return}; let items=store.clips.filter{selected.contains($0.id)}; do { try store.exportBackup(to:url,items:items) } catch {notice=error.localizedDescription} } }
    private var settingsPane: some View {
        ScrollView { VStack(alignment:.leading,spacing:20) {
            settingsSection("STORAGE") { Text(store.storageDirectory.path).font(.system(size:11)).textSelection(.enabled); Text("Using \(ByteCountFormatter.string(fromByteCount:store.storageBytes,countStyle:.file))").font(.system(size:12)).foregroundStyle(.secondary); HStack{Button("Open Finder"){NSWorkspace.shared.open(store.storageDirectory)};Button("Choose attachment folder"){let p=NSOpenPanel();p.canChooseDirectories=true;p.canChooseFiles=false;p.begin{if $0 == .OK,let u=p.url {store.setAttachmentDirectory(u)}}}};Text("Attachments: \(store.attachmentDirectory.path)").font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled) }
            settingsSection("DELETION") {
                Toggle("Delete stored attachments with history by default", isOn: $store.deleteStoredFilesByDefault)
                Text("Only ClipToMac’s local copies are removed after Undo expires. Original files and the phone’s copies are kept.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            settingsSection("BACKUP") { HStack { Button("Export backup…"){backupExport()}; Button("Import backup…"){backupImport()} }; Text("Backups contain library entries and attachment files. Paired device credentials are never included.").font(.system(size:11)).foregroundStyle(.secondary) }
            settingsSection("GLOBAL SHORTCUT") { HStack { Text("Show / hide library"); Spacer(); Picker("Modifiers",selection:$store.shortcutModifiers){Text("⌘⌥").tag(UInt32(0x900));Text("⌘⇧").tag(UInt32(0x300));Text("⌃⌥").tag(UInt32(0x1800))}.labelsHidden().frame(width:90); Picker("Shortcut key",selection:$store.shortcutKeyCode){Text("V").tag(UInt32(9));Text("L").tag(UInt32(37));Text("Space").tag(UInt32(49));Text("C").tag(UInt32(8))}.labelsHidden().frame(width:100) }; Text("Registered as a system hotkey; ClipToMac does not monitor keystrokes.").font(.system(size:11)).foregroundStyle(.secondary) }
        }.padding(22) }
    }
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
    @ViewBuilder private var transferTray: some View {
        let active = (transfers.outboundItems + transfers.incomingItems).filter { !["delivered", "cancelled", "complete"].contains($0.state) }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("TRANSFERS · \(active.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(active.suffix(3)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).lineLimit(1)
                            Text("\(item.direction == "received" ? "From" : "To") \(item.deviceName) · \(item.state)").font(.system(size: 10)).foregroundStyle(.secondary)
                            if item.bytesPerSecond > 0, let remaining = item.estimatedSecondsRemaining {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file))/s · ETA \(Int(remaining) / 60)m \(Int(remaining) % 60)s").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(ByteCountFormatter.string(fromByteCount: item.bytesSent, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                            Text(item.totalBytes > 0 ? "\(Int(min(100, Double(item.bytesSent) / Double(item.totalBytes) * 100)))%" : "0%")
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                        if item.totalBytes > 0 { ProgressView(value: Double(item.bytesSent), total: Double(item.totalBytes)).frame(width: 65) }
                        if item.direction == "sent" {
                        Button(item.state == "paused" ? "Resume" : "Pause") { transfers.togglePause(id: item.id) }.buttonStyle(.bordered).controlSize(.small)
                        Button("Cancel") { transfers.cancel(id: item.id) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }.padding(12).background(.primary.opacity(0.035))
        }
    }
    private func settingsSection<Content:View>(_ title:String,@ViewBuilder content:()->Content)->some View { VStack(alignment:.leading,spacing:12){Text(title).font(.system(size:9,weight:.semibold)).tracking(1.4).foregroundStyle(.secondary);content()}.padding(15).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8)) }
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
    var body: some View { ZStack { if #available(macOS 26.0,*) { Color.clear.glassEffect(.regular,in:RoundedRectangle(cornerRadius:9)); RoundedRectangle(cornerRadius:9).fill(colorScheme == .dark ? Color.black.opacity(0.16):Color.white.opacity(0.16)) } else { VisualEffectView(material:.sidebar,blendingMode:.behindWindow) } } }
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
