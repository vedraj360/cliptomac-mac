import SwiftUI

/// Explicit neutral styling avoids the pale fill produced by a grey accent tint.
struct GraphiteButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    GraphiteButtonSurface(label: configuration.label, pressed: configuration.isPressed)
  }
}

private struct GraphiteButtonSurface<Label: View>: View {
  let label: Label
  let pressed: Bool
  @Environment(\.isEnabled) private var enabled
  @State private var hovering = false

  var body: some View {
    label
      .foregroundStyle(Color.white.opacity(enabled ? 0.96 : 0.45))
      .padding(.horizontal, 12).padding(.vertical, 10)
      .background(
        Color(white: pressed ? 0.13 : hovering ? 0.23 : 0.18), in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6).strokeBorder(
          Color.white.opacity(enabled ? (hovering ? 0.28 : 0.16) : 0.08), lineWidth: 1)
      )
      .opacity(enabled ? 1 : 0.65)
      .contentShape(RoundedRectangle(cornerRadius: 6))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
