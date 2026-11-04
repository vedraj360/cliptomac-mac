import SwiftUI

struct PhoneNotificationHistoryView: View {
    @ObservedObject var relay: PhoneNotificationRelay
    @State private var expandedApps: Set<String> = []
    @State private var expanded: Set<String> = []
    @State private var confirmingClear = false

    private var appGroups: [(name: String, entries: [PhoneNotificationRelay.HistoryEntry])] {
        let grouped = Dictionary(grouping: relay.history, by: \.appName)
        var seen = Set<String>()
        return relay.history.compactMap { entry in
            guard seen.insert(entry.appName).inserted, let entries = grouped[entry.appName] else { return nil }
            return (entry.appName, entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Phone Notifications").font(AppTypography.heading(size: 22))
                    Text("Recent alerts from your Android phone")
                        .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History") { confirmingClear = true }
                    .buttonStyle(GraphiteButtonStyle())
                    .disabled(relay.history.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()
            if relay.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell").font(.title2)
                    Text("No phone notifications yet").font(AppTypography.font(size: 13, weight: .semibold))
                    Text("Forwarded notifications will appear here.")
                        .font(AppTypography.font(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(appGroups, id: \.name) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.name)
                                    .font(AppTypography.font(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                let isOpen = expandedApps.contains(group.name)
                                ForEach(isOpen ? group.entries : Array(group.entries.prefix(1))) { entry in
                                    notificationRow(entry)
                                }
                                if group.entries.count > 1 {
                                    Button {
                                        if isOpen {
                                            expandedApps.remove(group.name)
                                        } else {
                                            expandedApps.insert(group.name)
                                        }
                                    } label: {
                                        Label(
                                            isOpen ? "Show Less" : "Show \(group.entries.count - 1) More",
                                            systemImage: isOpen ? "chevron.up" : "chevron.down"
                                        )
                                        .font(AppTypography.font(size: 11, weight: .medium))
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Clear phone notification history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                relay.clearHistory()
                expanded.removeAll()
                expandedApps.removeAll()
            }
        } message: {
            Text("This removes the notifications saved on this Mac.")
        }
    }

    private func notificationRow(_ entry: PhoneNotificationRelay.HistoryEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    sourceIcon(entry)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title.isEmpty || entry.title == entry.appName
                             ? entry.appName : "\(entry.appName) - \(entry.title)")
                            .font(AppTypography.font(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if !isExpanded && !entry.body.isEmpty {
                            Text(entry.body.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.receivedAt, format: .dateTime.hour().minute())
                        .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(AppTypography.font(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse message" : "Expand message")
            if isExpanded && !entry.body.isEmpty {
                Text(entry.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
    }

    private func sourceIcon(_ entry: PhoneNotificationRelay.HistoryEntry) -> some View {
        let package = entry.packageName ?? (entry.appName == "WhatsApp" ? "com.whatsapp" : "")
        return Group {
            if let icon = relay.sourceIcon(packageName: package) {
                Image(nsImage: icon).resizable().scaledToFit().padding(5)
            } else {
                Image(systemName: "bell").foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .background(.primary.opacity(0.06), in: Circle())
        .accessibilityHidden(true)
    }
}
