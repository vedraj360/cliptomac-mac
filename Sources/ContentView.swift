import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject private var store = ClipStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var search = ""
    @State private var settings = false
    @State private var confirmClear = false
    @State private var deleteClearFiles = false
    @State private var unpairTarget: PairedDevice?
    @State private var menuApp: KnownApp?
    @State private var selectedSendDeviceID: String?
    @StateObject private var clipboardSender = ClipboardSendController()
    @State private var showPhoneNotificationSettingsPrompt = false

    private var sendDevices: [PairedDevice] {
        store.pairedDevices.filter { $0.securePairing == true && !$0.token.isEmpty }
    }

    private var sendDevice: PairedDevice? {
        sendDevices.first(where: { $0.id == selectedSendDeviceID }) ?? sendDevices.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            TransferPanel(compact: true)
            if settings {
                PreferencesScreen(store: store, confirmClear: $confirmClear, deleteClearFiles: $deleteClearFiles, unpairTarget: $unpairTarget)
            } else {
                VStack(spacing: 0) {
                    sendActions
                    RecentClipsFeed(store: store, search: $search, selectedApp: $menuApp)
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
            } else if let payload = clipboardSender.review {
                ClipboardSendConfirmationView(
                    payload: payload,
                    canSend: sendDevice != nil && !clipboardSender.isSending,
                    onCancel: { clipboardSender.dismissReview() },
                    onSend: { if let sendDevice { clipboardSender.send(payload, to: sendDevice) } }
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

    private var sendActions: some View {
        SendToPhoneSection(
            devices: sendDevices,
            selectedDeviceID: $selectedSendDeviceID,
            isPreparingClipboard: clipboardSender.isSending,
            notice: clipboardSender.notice,
            onSendClipboard: clipboardSender.prepareReview,
            onAttachFile: clipboardSender.chooseAttachment(for:)
        )
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

/// Clear glass allows desktop text to show through almost unchanged. The
/// regular native material diffuses that detail; a small neutral scrim keeps
/// foreground text readable over both bright windows and dark wallpaper.
struct ReadableGlassBackground: View {
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
