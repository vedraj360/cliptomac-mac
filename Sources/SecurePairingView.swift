import SwiftUI
import CoreImage.CIFilterBuiltins

struct SecurePairingView: View {
    @ObservedObject private var pairing = SecurePairing.shared
    @ObservedObject private var store = ClipStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.connectionState() == .securePairingRequired ? "Secure pairing required" : (store.connectionState() == .unpaired ? "Pair your phone" : "Phone pairing")).font(.system(size: 15, weight: .semibold))
            Text(store.connectionExplanation)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let payload = pairing.payload, let image = PairingQRCode.image(payload) {
                HStack { Spacer(); Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 6)); Spacer() }
                HStack {
                    Button("Copy pairing code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payload, forType: .string) }
                    Spacer(); Button("Cancel") { pairing.close() }
                }.font(.system(size: 11))
            } else {
                if store.connectionState() == .connected || store.connectionState() == .offline {
                    Text("Already paired. A QR is only needed to add another phone or pair again.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Button(store.connectionState() == .connected || store.connectionState() == .offline ? "Add or re-pair a phone" : "Show pairing QR") { store.updateLocalIP(); pairing.open(host: store.localIP, port: store.port) }.buttonStyle(.borderedProminent)
            }
            if let error = pairing.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
        }
    }
}
