import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class ClipboardSendController: ObservableObject {
    @Published private(set) var review: ClipboardSendPayload?
    @Published private(set) var notice: String?
    @Published private(set) var isSending = false

    func dismissReview() { review = nil }

    func prepareReview() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            review = .files(urls)
            return
        }
        if let image = NSImage(pasteboard: pasteboard), image.isValid,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            review = .image(png)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            review = .text(text)
            return
        }
        notice = "The clipboard has no sendable text, image, or file."
    }

    func chooseAttachment(for device: PairedDevice) {
        let panel = NSOpenPanel()
        panel.title = "Choose a file to send to \(device.name)"
        panel.prompt = "Send File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await self?.queueFile(url, to: device) }
                catch { self?.notice = error.localizedDescription }
            }
        }
    }

    func send(_ payload: ClipboardSendPayload, to device: PairedDevice) {
        review = nil
        isSending = true
        notice = "Preparing clipboard…"
        Task { @MainActor in
            defer { isSending = false }
            do {
                switch payload {
                case .text(let text):
                    _ = try MacTransferService.shared.sendText(text, to: device)
                    notice = "Clipboard queued for \(device.name)."
                case .image(let data):
                    let source = ClipStore.shared.attachmentDirectory.appendingPathComponent("clipboard-\(UUID().uuidString).png")
                    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: source, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: source) }
                    _ = try await MacTransferService.shared.sendFile(source, to: device)
                    notice = "Clipboard image queued for \(device.name)."
                case .files(let urls):
                    var queued = 0
                    for url in urls {
                        notice = "Preparing \(url.lastPathComponent)…"
                        try await queueFile(url, to: device, updateNotice: false)
                        queued += 1
                    }
                    notice = "\(queued) \(queued == 1 ? "file" : "files") queued for \(device.name)."
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func queueFile(_ url: URL, to device: PairedDevice, updateNotice: Bool = true) async throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        if updateNotice { notice = "Preparing \(url.lastPathComponent)…" }
        _ = try await MacTransferService.shared.sendFile(url, to: device)
        if updateNotice { notice = "File queued for \(device.name)." }
    }
}
