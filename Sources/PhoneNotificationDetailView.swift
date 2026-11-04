import AppKit
import SwiftUI

struct PhoneNotificationDetailView: View {
  let appName: String
  let title: String
  let bodyText: String
  let sendReply: ((String) -> Bool)?
  @State private var reply = ""
  @State private var replyFailed = false
  @FocusState private var replyFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.bubble.right.fill")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(appName).font(AppTypography.font(size: 12, weight: .semibold))
          Text(title).font(AppTypography.font(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(bodyText, forType: .string)
        }
        .buttonStyle(.bordered)
        if sendReply == nil {
          Button("Close") { AppDelegate.shared?.closePhoneNotificationDetail() }
            .keyboardShortcut(.cancelAction)
        }
      }
      Divider()
      ScrollView {
        Text(bodyText)
          .font(AppTypography.font(size: 13))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 2)
      }
      if let sendReply {
        Divider()
        TextField("Reply", text: $reply)
          .textFieldStyle(.roundedBorder)
          .focused($replyFocused)
          .task { replyFocused = true }
        if replyFailed {
          Text("This reply could not be queued. The notification may have expired.")
            .font(AppTypography.font(size: 11))
            .foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Cancel") { AppDelegate.shared?.closePhoneNotificationDetail() }
            .keyboardShortcut(.cancelAction)
          Button("Send") {
            if sendReply(reply) {
              AppDelegate.shared?.closePhoneNotificationDetail()
            } else {
              replyFailed = true
            }
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .padding(20)
    .frame(minWidth: 420, minHeight: 250)
    .background(.regularMaterial)
  }
}
