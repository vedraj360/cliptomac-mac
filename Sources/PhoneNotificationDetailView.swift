import SwiftUI
import AppKit

struct PhoneNotificationDetailView: View {
    let appName: String
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName).font(.system(size: 12, weight: .semibold))
                    Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bodyText, forType: .string)
                }
                .buttonStyle(.bordered)
                Button("Close") { AppDelegate.shared?.closePhoneNotificationDetail() }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                Text(bodyText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 250)
        .background(.regularMaterial)
    }
}
