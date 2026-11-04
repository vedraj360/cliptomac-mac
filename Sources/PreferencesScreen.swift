import SwiftUI

struct PreferencesScreen: View {
  @ObservedObject var store: ClipStore
  @Binding var confirmClear: Bool
  @Binding var deleteClearFiles: Bool
  @Binding var unpairTarget: PairedDevice?

  var embedded = false

  var body: some View {
    if embedded {
      sections
    } else {
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
          sections.padding(20).id("settings-top")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { proxy.scrollTo("settings-top", anchor: .top) }
        .onReceive(
          NotificationCenter.default.publisher(for: Notification.Name("ClipToMacMenuOpened"))
        ) { _ in
          proxy.scrollTo("settings-top", anchor: .top)
        }
      }
    }
  }

  private var sections: some View {
    VStack(alignment: .leading, spacing: 22) {
      section("SECURE PAIRING") { SecurePairingView() }
      section("PREFERENCES") {
        preference(
          "Launch at login", subtitle: "Ready when your Mac starts", value: $store.launchAtLogin
        )
        Divider().opacity(0.3)
        preference(
          "Copy on arrival", subtitle: "Paste a received clip with ⌘V", value: $store.autoCopy)
        Divider().opacity(0.3)
        preference(
          "Notifications", subtitle: "Show new clips in Notification Center",
          value: $store.showNotifications)
        Divider().opacity(0.3)
        if !embedded {
          preference(
            "Delete stored files", subtitle: "Default choice when deleting attachment history",
            value: $store.deleteStoredFilesByDefault)
        }
        preference(
          "Receive sound", subtitle: "A quiet cue for new clips and custom phone banners", value: $store.playSound)
      }
      phoneNotifications
      pairedPhones
      connection
      Button("Clear received history…", role: .destructive) {
        deleteClearFiles = store.deleteStoredFilesByDefault
        confirmClear = true
      }
      .buttonStyle(.plain).font(AppTypography.font(size: 12))
      .disabled(store.clips.isEmpty)
    }
  }

  private var phoneNotifications: some View {
    section("PHONE NOTIFICATIONS") {
      preference(
        "Forward Android notifications", subtitle: "Show alerts from apps selected on your phone",
        value: Binding(
          get: { store.phoneNotificationRelayEnabled },
          set: { store.setPhoneNotificationRelayEnabled($0) }
        ))
      VStack(alignment: .leading, spacing: 6) {
        Picker("Alert style", selection: $store.showSourceAppBanners) {
          Text("macOS notifications").tag(false)
          Text("Custom banners").tag(true)
        }
        .pickerStyle(.segmented)
        Text(store.showSourceAppBanners
             ? "Shows the source app icon and inline actions. Custom banners do not appear in Notification Center or follow macOS Focus."
             : "Shows desktop alerts and Notification Center entries according to your macOS notification and Focus settings.")
          .font(AppTypography.font(size: 10))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .disabled(!store.phoneNotificationRelayEnabled)
      Button {
        AppDelegate.shared?.openPhoneNotificationHistory()
      } label: {
        Label("Open Phone Notifications", systemImage: "bell")
      }
      .buttonStyle(GraphiteButtonStyle())
      if let permissionMessage = store.phoneNotificationPermissionMessage {
        HStack(alignment: .top, spacing: 8) {
          Text(permissionMessage).font(AppTypography.font(size: 10)).foregroundStyle(.secondary)
          Spacer(minLength: 4)
          Button("Open Settings") { store.openPhoneNotificationSettings() }
            .buttonStyle(.plain).font(AppTypography.font(size: 10, weight: .medium))
        }
      }
      if !store.showSourceAppBanners {
        focusSettings
      }
      Text("The last 50 forwarded alerts are saved in Phone Notifications in either mode.")
        .font(AppTypography.font(size: 10)).foregroundStyle(.secondary)
    }
  }

  private var focusSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "moon.zzz.fill")
            .font(AppTypography.font(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
          VStack(alignment: .leading, spacing: 3) {
            Text("Show alerts during Focus").font(AppTypography.font(size: 11, weight: .medium))
            Text("Allow ClipToMac in each Focus where you want forwarded alerts.")
              .font(AppTypography.font(size: 10)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Button {
          store.openFocusSettings()
        } label: {
          Label("Manage Focus Settings", systemImage: "slider.horizontal.3")
            .font(AppTypography.font(size: 10, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GraphiteButtonStyle())
    }
  }

  private var pairedPhones: some View {
    section("PAIRED PHONES") {
      if store.pairedDevices.isEmpty {
        Text("Find this Mac from the Android app to pair.")
          .font(AppTypography.font(size: 12)).foregroundStyle(.secondary)
      }
      ForEach(store.pairedDevices) { device in
        HStack(spacing: 10) {
          Image(systemName: "iphone").foregroundStyle(.secondary)
          Text(device.name + (device.securePairing == true ? "" : " · Re-pair required"))
            .font(AppTypography.font(size: 12, weight: .medium))
          Spacer()
          Button("Unpair") { unpairTarget = device }
            .font(AppTypography.font(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
      }
    }
  }

  private var connection: some View {
    section("CONNECTION") {
      HStack {
        Text("Mac address").foregroundStyle(.secondary)
        Spacer()
        Text(verbatim: "\(store.localIP):\(store.port)")
          .monospacedDigit().textSelection(.enabled)
      }.font(AppTypography.font(size: 11))
      Text("Keep both devices on the same Wi-Fi network.")
        .font(AppTypography.font(size: 11)).foregroundStyle(.secondary)
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(AppTypography.heading(size: 10)).tracking(1.5).foregroundStyle(
        .secondary)
      VStack(alignment: .leading, spacing: 12, content: content)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.07)))
    }
  }

  private func preference(_ title: String, subtitle: String, value: Binding<Bool>) -> some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(AppTypography.font(size: 12, weight: .medium))
        Text(subtitle).font(AppTypography.font(size: 10)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(title, isOn: value)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(title)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 3)
  }
}
