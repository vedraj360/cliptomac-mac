import SwiftUI

enum ClipboardSendPayload {
    case text(String)
    case image(Data)
    case files([URL])

    var title: String {
        switch self {
        case .text: return "Clipboard text"
        case .image: return "Clipboard image"
        case .files(let urls): return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files from clipboard"
        }
    }

    var preview: String {
        switch self {
        case .text(let value): return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        case .image: return "The image currently copied on your Mac will be sent as a PNG."
        case .files(let urls): return urls.prefix(4).map(\.lastPathComponent).joined(separator: "\n") + (urls.count > 4 ? "\n… and \(urls.count - 4) more" : "")
        }
    }
}

struct SendToPhoneSection: View {
    let devices: [PairedDevice]
    @Binding var selectedDeviceID: String?
    let isPreparingClipboard: Bool
    let notice: String?
    let onSendClipboard: () -> Void
    let onAttachFile: (PairedDevice) -> Void

    private var selectedDevice: PairedDevice? {
        devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("SEND TO PHONE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                Spacer()
                if devices.count > 1 {
                    Menu {
                        ForEach(devices) { device in
                            Button { selectedDeviceID = device.id } label: {
                                if device.id == selectedDevice?.id { Label(device.name, systemImage: "checkmark") }
                                else { Text(device.name) }
                            }
                        }
                    } label: {
                        Label(selectedDevice?.name ?? "Choose phone", systemImage: "iphone")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                } else if let device = selectedDevice {
                    Label(device.name, systemImage: "iphone").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Pair a phone to send").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: onSendClipboard) {
                    Label(isPreparingClipboard ? "Preparing…" : "Send clipboard", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(selectedDevice == nil || isPreparingClipboard)
                .help("Review and send the current Mac clipboard")

                Button { if let selectedDevice { onAttachFile(selectedDevice) } } label: {
                    Label("Attach file", systemImage: "paperclip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(selectedDevice == nil)
                .help("Choose a file to send to the paired phone")
            }

            if let notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct ClipboardSendConfirmationView: View {
    let payload: ClipboardSendPayload
    let canSend: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.30).onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 13) {
                Text("SEND CLIPBOARD").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text(payload.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                Text(payload.preview.isEmpty ? "The clipboard is empty." : payload.preview)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                HStack {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Send", action: onSend)
                        .buttonStyle(GraphiteButtonStyle())
                        .disabled(!canSend)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 330, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        }
    }
}
