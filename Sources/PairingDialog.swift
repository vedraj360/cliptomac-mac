import SwiftUI
import AppKit

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
