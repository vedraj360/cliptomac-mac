import SwiftUI

struct TransferPanel: View {
    @ObservedObject private var transfers = MacTransferService.shared
    var compact = false
    var body: some View {
        let active = (transfers.incomingItems + transfers.outboundItems).filter { !["complete", "delivered", "cancelled"].contains($0.state) }.sorted { $0.createdAt > $1.createdAt }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("TRANSFERS · \(active.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(active.prefix(compact ? 1 : 3))) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(Int(min(100, Double(item.bytesSent) / Double(max(1, item.totalBytes)) * 100)))%").monospacedDigit()
                        }
                        Text("\(item.direction == "received" ? "Receiving from" : "Sending to") \(item.deviceName) · \(item.state)").foregroundStyle(.secondary)
                        ProgressView(value: Double(item.bytesSent), total: Double(max(1, item.totalBytes)))
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: item.bytesSent, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                            Spacer()
                            Text(item.state == "verifying" ? "Verifying checksum…" : item.bytesPerSecond > 0 ? "\(ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file))/s" : "Measuring speed…")
                            Text(item.state == "verifying" ? "" : item.estimatedSecondsRemaining.map { "ETA \(Int($0) / 60)m \(Int($0) % 60)s" } ?? "ETA calculating…")
                        }.monospacedDigit().foregroundStyle(.secondary)
                        if item.direction == "sent" {
                            HStack {
                                Button(item.state == "paused" ? "Resume" : "Pause") { transfers.togglePause(id: item.id) }
                                Button("Cancel") { transfers.cancel(id: item.id) }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.font(.system(size: 10))
                }
            }.padding(compact ? 14 : 12).background(.primary.opacity(0.04))
        }
    }
}
