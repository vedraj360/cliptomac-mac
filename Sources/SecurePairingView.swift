import SwiftUI
import CoreImage.CIFilterBuiltins

struct SecurePairingView: View {
    @ObservedObject private var pairing = SecurePairing.shared
    @ObservedObject private var store = ClipStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair securely").font(.system(size: 15, weight: .semibold))
            Text("On your phone, tap Pair Mac and scan this QR. Keep the code private. It expires in two minutes.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let payload = pairing.payload, let image = PairingQRCode.image(payload) {
                HStack { Spacer(); Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 6)); Spacer() }
                HStack {
                    Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payload, forType: .string) }
                    Spacer(); Button("Cancel") { pairing.close() }
                }.font(.system(size: 11))
            } else {
                Button("Show pairing QR") { store.updateLocalIP(); pairing.open(host: store.localIP, port: store.port) }.buttonStyle(.borderedProminent)
            }
            if let error = pairing.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
    }
}
