import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct ContentView: View {
    @ObservedObject private var store = ClipStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var search = ""
    @State private var settings = false
    @State private var copiedID: UUID?
    @State private var copyErrorID: UUID?
    @State private var confirmClear = false
    @State private var deleteClearFiles = false
    @State private var unpairTarget: PairedDevice?
    @State private var menuApp: KnownApp?
    @State private var selectedSendDeviceID: String?
    @State private var clipboardReview: ClipboardSendPayload?
    @State private var sendNotice: String?
    @State private var sendingClipboard = false
    @State private var showPhoneNotificationSettingsPrompt = false

    private var sendDevices: [PairedDevice] {
        store.pairedDevices.filter { $0.securePairing == true && !$0.token.isEmpty }
    }

    private var sendDevice: PairedDevice? {
        sendDevices.first(where: { $0.id == selectedSendDeviceID }) ?? sendDevices.first
    }

    private var filtered: [ClipItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = query.isEmpty ? store.clips : store.clips.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
        return items.filter { menuApp == nil || $0.sourceApp == menuApp }.sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            TransferPanel(compact: true)
            if settings { preferences } else {
                VStack(spacing: 0) {
                    sendActions
                    feed
                }
            }
            footer.zIndex(1)
        }
        .font(.system(size: 13, design: .default))
        .frame(width: 420, height: 620)
        .background { nativeGlass }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.15 : 0.5), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .tint(Color(white: 0.72))
        .overlay {
            if confirmClear {
                AttachmentDeleteSheet(count: store.clips.count, hasAttachments: store.clips.contains { $0.attachmentPath != nil }, deleteFiles: $deleteClearFiles) {
                    store.removeClips(ids: Set(store.clips.map(\.id)), deleteFiles: deleteClearFiles); confirmClear = false
                } onCancel: { confirmClear = false }
            } else if let device = unpairTarget {
                confirmationPanel(title: "Unpair \(device.name)?", message: "You can pair this phone again from its ClipToMac app.", action: "Unpair", destructive: true) {
                    store.unpairDevice(id: device.id)
                    unpairTarget = nil
                } cancel: { unpairTarget = nil }
            } else if let payload = clipboardReview {
                ClipboardSendConfirmationView(
                    payload: payload,
                    canSend: sendDevice != nil && !sendingClipboard,
                    onCancel: { clipboardReview = nil },
                    onSend: { sendClipboard(payload) }
                )
            } else if showPhoneNotificationSettingsPrompt {
                confirmationPanel(
                    title: "Allow Mac notifications",
                    message: store.phoneNotificationPermissionMessage ?? "Allow ClipToMac alerts and sound in System Settings to hear forwarded Android notifications.",
                    action: "Open Notification Settings",
                    destructive: false
                ) {
                    showPhoneNotificationSettingsPrompt = false
                    store.openPhoneNotificationSettings()
                } cancel: {
                    showPhoneNotificationSettingsPrompt = false
                }
            }
        }
        .onAppear {
            selectedSendDeviceID = sendDevices.first?.id
            store.refreshPhoneNotificationPermission()
        }
        .onChange(of: store.pairedDevices) { devices in
            let eligible = devices.first(where: { $0.id == selectedSendDeviceID && $0.securePairing == true && !$0.token.isEmpty })
            selectedSendDeviceID = eligible?.id ?? devices.first(where: { $0.securePairing == true && !$0.token.isEmpty })?.id
        }
        .onChange(of: store.phoneNotificationSettingsPromptRequested) { requested in
            if requested {
                showPhoneNotificationSettingsPrompt = true
                store.phoneNotificationSettingsPromptRequested = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshPhoneNotificationPermission()
        }
    }

    private var nativeGlass: some View {
        ReadableGlassBackground()
    }

    private func confirmationPanel(title: String, message: String, action: String, destructive: Bool,
        confirm: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.28).onTapGesture(perform: cancel)
            VStack(alignment: .leading, spacing: 16) {
                Text("CLIPTOMAC").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                Text(title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                HStack(spacing: 10) {
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action, action: confirm)
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                }.buttonStyle(.bordered).controlSize(.large)
            }
            .padding(22)
            .frame(width: 330, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CLIPTOMAC")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(2.2)
                        .foregroundStyle(.secondary)
                    Text(settings ? "Settings" : "Your clipboard, closer.")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.6)
                }
                Spacer(minLength: 10)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { settings.toggle() }
                } label: {
                    Image(systemName: settings ? "xmark" : "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(settings ? "Close settings" : "Settings")
                .accessibilityLabel(settings ? "Close settings" : "Settings")
            }
            HStack(spacing: 7) {
                Circle().fill(store.connectionState() == .connected ? Color.green : (store.connectionState() == .securePairingRequired ? Color.orange : Color.secondary.opacity(0.5)))
                    .frame(width: 6, height: 6)
                Text(store.connectionSummary)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Button { AppDelegate.shared?.openLibrary() } label: {
                    Label("Open Library", systemImage: "square.grid.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Open your full clip library")
                .accessibilityLabel("Open full clip library")
            }.help(store.connectionExplanation)
            if !settings && (store.connectionState() == .unpaired || store.connectionState() == .securePairingRequired) {
                Button {
                    store.updateLocalIP()
                    settings = true
                    SecurePairing.shared.open(host: store.localIP, port: store.port)
                } label: {
                    Label(store.connectionState() == .unpaired ? "Pair phone" : "Pair securely", systemImage: "qrcode")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GraphiteButtonStyle())
                .help("Open a fresh QR to pair your phone")
            }
        }
        .padding(20)
    }

    private var feed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clips or apps", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(11)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if !store.clips.isEmpty {
                HStack(spacing: 6) {
                    Button("Recent") { menuApp = nil }.buttonStyle(.bordered).controlSize(.small)
                    ForEach(Array(Set(store.clips.map(\.sourceApp))).filter { $0 != .generic }.sorted { $0.rawValue < $1.rawValue }, id: \.self) { app in
                        Button(app.rawValue) { menuApp = app }.buttonStyle(.bordered).controlSize(.small)
                    }
                }.padding(.horizontal,20).padding(.top,10).frame(maxWidth:.infinity,alignment:.leading)
            }

            HStack {
                Text("RECEIVED")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.5)
                Spacer()
                Text("\(filtered.count) \(filtered.count == 1 ? "clip" : "clips")")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 21)
            .padding(.top, 18)
            .padding(.bottom, 10)

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    Text(search.isEmpty ? "Ready for your next idea." : "No matching clips")
                        .font(.system(size: 16, weight: .medium))
                    Text(search.isEmpty ? "Copy text on your phone, then tap\nSend to Mac in the top overlay." : "Try another word or app name.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 9) {
                        ForEach(filtered) { clip in card(clip) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var sendActions: some View {
        SendToPhoneSection(
            devices: sendDevices,
            selectedDeviceID: $selectedSendDeviceID,
            isPreparingClipboard: sendingClipboard,
            notice: sendNotice,
            onSendClipboard: prepareClipboardReview,
            onAttachFile: chooseAttachment(for:)
        )
    }

    private func prepareClipboardReview() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            clipboardReview = .files(urls)
            return
        }
        if let image = NSImage(pasteboard: pasteboard), image.isValid,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            clipboardReview = .image(png)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clipboardReview = .text(text)
            return
        }
        sendNotice = "The clipboard has no sendable text, image, or file."
    }

    private func chooseAttachment(for device: PairedDevice) {
        let panel = NSOpenPanel()
        panel.title = "Choose a file to send to \(device.name)"
        panel.prompt = "Send File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await queueFile(url, to: device) }
                catch { sendNotice = error.localizedDescription }
            }
        }
    }

    private func sendClipboard(_ payload: ClipboardSendPayload) {
        guard let device = sendDevice else { return }
        clipboardReview = nil
        sendingClipboard = true
        sendNotice = "Preparing clipboard…"
        Task { @MainActor in
            do {
                switch payload {
                case .text(let text):
                    _ = try MacTransferService.shared.sendText(text, to: device)
                    sendNotice = "Clipboard queued for \(device.name)."
                case .image(let data):
                    let source = ClipStore.shared.attachmentDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).png")
                    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: source, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: source) }
                    _ = try await MacTransferService.shared.sendFile(source, to: device)
                    sendNotice = "Clipboard image queued for \(device.name)."
                case .files(let urls):
                    var queued = 0
                    for url in urls {
                        sendNotice = "Preparing \(url.lastPathComponent)…"
                        try await queueFile(url, to: device, updateNotice: false)
                        queued += 1
                    }
                    sendNotice = "\(queued) \(queued == 1 ? "file" : "files") queued for \(device.name)."
                }
            } catch {
                sendNotice = error.localizedDescription
            }
            sendingClipboard = false
        }
    }

    @MainActor
    private func queueFile(_ url: URL, to device: PairedDevice, updateNotice: Bool = true) async throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        if updateNotice { sendNotice = "Preparing \(url.lastPathComponent)…" }
        _ = try await MacTransferService.shared.sendFile(url, to: device)
        if updateNotice { sendNotice = "File queued for \(device.name)." }
    }

    private func card(_ clip: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                SourceAppIcon(app: clip.sourceApp, package: clip.packageName).frame(width: 22, height: 22)
                Text(clip.appName).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(clip.relativeTime).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(clip.exactTime)
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
                        let success: Bool
                        if clip.kind == .image { success = store.copyImageToClipboard(clip) }
                        else { store.copyToClipboard(clip); success = true }
                        if success { copiedID = clip.id; copyErrorID = nil }
                        else { copyErrorID = clip.id }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copiedID == clip.id { copiedID = nil }
                            if copyErrorID == clip.id { copyErrorID = nil }
                        }
                    } label: {
                        Label(copyErrorID == clip.id ? "Couldn’t copy" : (copiedID == clip.id ? "Copied" : (clip.kind == .image ? "Copy image" : "Copy")), systemImage: copiedID == clip.id ? "checkmark" : "doc.on.doc")
                    }.foregroundStyle(copyErrorID == clip.id ? Color.orange : (copiedID == clip.id ? Color.green : Color.primary))
                }
                if let path = clip.attachmentPath {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                if clip.isURL, let url = URL(string: clip.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Open", systemImage: "arrow.up.right")
                    }
                }
                Spacer()
                Button { withAnimation { store.removeClips(ids: [clip.id]) } } label: {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
                .help("Delete clip").accessibilityLabel("Delete clip")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.16))
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.075), lineWidth: 0.7))
    }

    private var preferences: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 22) {
                section("SECURE PAIRING") { SecurePairingView() }
                section("PREFERENCES") {
                    preference("Launch at login", subtitle: "Ready when your Mac starts", value: $store.launchAtLogin)
                    Divider().opacity(0.3)
                    preference("Copy on arrival", subtitle: "Paste a received clip with ⌘V", value: $store.autoCopy)
                    Divider().opacity(0.3)
                    preference("Notifications", subtitle: "Show new clips in Notification Center", value: $store.showNotifications)
                    Divider().opacity(0.3)
                    preference("Delete stored files", subtitle: "Default choice when deleting attachment history", value: $store.deleteStoredFilesByDefault)
                    preference("Receive sound", subtitle: "A quiet cue for new clips", value: $store.playSound)
                }
                section("PHONE NOTIFICATIONS") {
                    preference("Forward Android notifications", subtitle: "Show alerts from apps selected on your phone", value: Binding(
                        get: { store.phoneNotificationRelayEnabled },
                        set: { store.setPhoneNotificationRelayEnabled($0) }
                    ))
                    if let permissionMessage = store.phoneNotificationPermissionMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Text(permissionMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button("Open Settings") { store.openPhoneNotificationSettings() }
                                .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: 30)
                                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Show alerts during Focus")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Allow ClipToMac in each Focus where you want forwarded alerts.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Button { store.openFocusSettings() } label: {
                            Label("Manage Focus Settings", systemImage: "slider.horizontal.3")
                                .font(.system(size: 10, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(GraphiteButtonStyle())
                        Text("Forwarded alerts stay in Notification Center, not clip history.")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                section("PAIRED PHONES") {
                    if store.pairedDevices.isEmpty {
                        Text("Find this Mac from the Android app to pair.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            Text(device.name + (device.securePairing == true ? "" : " · Re-pair required")).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Button("Unpair") { unpairTarget = device }
                                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
                section("CONNECTION") {
                    HStack {
                        Text("Mac address").foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(store.localIP):\(store.port)")
                            .monospacedDigit().textSelection(.enabled)
                    }.font(.system(size: 11))
                    Text("Keep both devices on the same Wi-Fi network.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button("Clear received history…", role: .destructive) { deleteClearFiles = store.deleteStoredFilesByDefault; confirmClear = true }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .disabled(store.clips.isEmpty)
            }
            .padding(20)
            .id("settings-top")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { proxy.scrollTo("settings-top", anchor: .top) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ClipToMacMenuOpened"))) { _ in
            proxy.scrollTo("settings-top", anchor: .top)
        }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
        }
    }

    private func preference(_ title: String, subtitle: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.left").font(.system(size: 9, weight: .medium))
            Text(store.connectionSummary).font(.system(size: 10)).help(store.connectionExplanation)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.primary.opacity(0.025))
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

@MainActor
enum PairingDialog {
    private static var presenting = false

    static func request(deviceName: String, code: String) -> Bool {
        guard !presenting else { return false }
        presenting = true
        defer { presenting = false }
        let panel = GlassMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.contentView = TransparentHostingView(rootView: PairingDialogContent(deviceName: deviceName, code: code) { accepted in
            NSApp.stopModal(withCode: accepted ? .OK : .cancel)
            panel.orderOut(nil)
        })
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The Android pairing request waits for one minute. Do not leave an
        // expired confirmation on screen after the request has timed out.
        let timeout = Timer(timeInterval: 55, repeats: false) { _ in
            NSApp.stopModal(withCode: .cancel)
            panel.orderOut(nil)
        }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        let result = NSApp.runModal(for: panel)
        timeout.invalidate()
        panel.orderOut(nil)
        panel.contentView = nil
        return result == .OK
    }
}

private struct PairingDialogContent: View {
    let deviceName: String
    let code: String
    let respond: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "iphone").font(.system(size: 23, weight: .light))
                Spacer()
                Text("CLIPTOMAC").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your phone").font(.system(size: 23, weight: .semibold))
                Text("\(deviceName) wants to send clips to this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VERIFICATION CODE").font(.system(size: 8, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Text(code).font(.system(size: 28, weight: .medium, design: .monospaced)).tracking(6)
                }
                Spacer()
            }
            .padding(14)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button("Decline") { respond(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Accept & pair") { respond(true) }
            }.buttonStyle(.bordered).controlSize(.large)
        }
        .padding(24)
        .frame(width: 390, height: 320)
        .background { ReadableGlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2), lineWidth: 0.7))
    }
}

/// Clear glass allows desktop text to show through almost unchanged. The
/// regular native material diffuses that detail; a small neutral scrim keeps
/// foreground text readable over both bright windows and dark wallpaper.
private struct ReadableGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.16))
            } else {
                VisualEffectView(material: .popover, blendingMode: .behindWindow)
            }
        }
        .allowsHitTesting(false)
    }
}
