import CoreImage.CIFilterBuiltins
import SwiftUI

struct SecurePairingView: View {
  @ObservedObject private var pairing = SecurePairing.shared
  @ObservedObject private var store = ClipStore.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        store.connectionState() == .securePairingRequired
          ? "Secure pairing required"
          : (store.connectionState() == .unpaired ? "Pair your phone" : "Phone pairing")
      ).font(AppTypography.font(size: 14, weight: .semibold))
      Text(store.connectionExplanation)
        .font(AppTypography.font(size: 11)).foregroundStyle(.secondary).lineSpacing(1).fixedSize(
          horizontal: false, vertical: true)
      if let payload = pairing.payload {
        PairingQRImage(payload: payload).equatable()
        Label(
          String(
            format: "Expires in %d:%02d", pairing.remainingSeconds / 60,
            pairing.remainingSeconds % 60), systemImage: "timer"
        )
        .font(AppTypography.font(size: 12, weight: .semibold)).monospacedDigit()
        .foregroundStyle(pairing.remainingSeconds <= 15 ? Color.orange : Color.primary)
        HStack {
          Button("Copy pairing code") {
            pairing.refreshRemaining()
            if let current = pairing.payload {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(current, forType: .string)
            }
          }
          Spacer()
          Button("Cancel") { pairing.close() }
        }.font(AppTypography.font(size: 11))
      } else {
        if pairing.expired {
          Label("QR expired", systemImage: "clock.badge.exclamationmark").font(
            AppTypography.font(size: 13, weight: .semibold)
          ).foregroundStyle(.orange)
          Text("Generate a new QR to continue pairing. The previous code no longer works.").font(
            AppTypography.font(size: 12)
          ).foregroundStyle(.secondary)
        }
        Button(
          pairing.expired
            ? "Generate new QR"
            : (store.connectionState() == .connected || store.connectionState() == .awaitingActivity
              ? "Add or re-pair a phone" : "Show pairing QR")
        ) {
          store.updateLocalIP()
          pairing.open(host: store.localIP, port: store.port)
        }.buttonStyle(GraphiteButtonStyle())
      }
      if let error = pairing.error { Text(error).font(AppTypography.font(size: 11)).foregroundStyle(.red) }
    }
  }
}

private struct PairingQRImage: View, Equatable {
  let payload: String
  var body: some View {
    HStack {
      Spacer()
      if let image = PairingQRCode.image(payload) {
        Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260)
          .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 6))
      }
      Spacer()
    }
  }
}
