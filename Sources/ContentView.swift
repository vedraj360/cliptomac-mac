import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject private var store = ClipStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var search = ""
    @State private var settings = false
    @State private var copiedID: UUID?
    @State private var confirmClear = false
    @State private var deleteClearFiles = false
    @State private var unpairTarget: PairedDevice?
    @State private var menuApp: KnownApp?

    private var filtered: [ClipItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = query.isEmpty ? store.clips : store.clips.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
        return items.filter { menuApp == nil || $0.sourceApp == menuApp }.sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            if settings { preferences } else { feed }
            footer
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
            }
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
                Circle().fill(store.hasPairedDevices ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(store.hasPairedDevices ? store.pairedDevicesSummary : "Pair a phone to get started")
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
                Button {
                    if clip.kind == .text { store.copyToClipboard(clip) }
                    else if let path = clip.attachmentPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    copiedID = clip.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedID == clip.id { copiedID = nil }
                    }
                } label: {
                    Label(clip.kind == .text ? (copiedID == clip.id ? "Copied" : "Copy") : "Reveal", systemImage: copiedID == clip.id ? "checkmark" : "doc.on.doc")
                }
                .foregroundStyle(copiedID == clip.id ? Color.green : Color.primary)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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
                section("PAIRED PHONES") {
                    if store.pairedDevices.isEmpty {
                        Text("Find this Mac from the Android app to pair.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(store.pairedDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            Text(device.name).font(.system(size: 12, weight: .medium))
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
            Text("Ready to receive").font(.system(size: 10))
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
