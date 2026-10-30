import AppKit
import SwiftUI

/// A faint backing gives WindowServer a hit-testable surface beneath refractive glass.
final class GlassMenuPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .scrollWheel && routeScroll(event, at: event.locationInWindow) { return }
    super.sendEvent(event)
  }
  /// Consume wheel events inside this panel, including gaps/header and scroll limits.
  /// No event taps or monitors intercept scrolling outside the panel.
  @discardableResult func routeScroll(_ event: NSEvent, at point: NSPoint) -> Bool {
    guard let contentView, contentView.bounds.contains(contentView.convert(point, from: nil)) else {
      return false
    }
    if let target = scrollView(in: contentView, at: point) { target.scrollWheel(with: event) }
    return true
  }
  private func scrollView(in view: NSView, at point: NSPoint) -> NSScrollView? {
    guard !view.isHidden, view.alphaValue > 0, view.bounds.contains(view.convert(point, from: nil))
    else { return nil }
    for child in view.subviews.reversed() {
      if let found = scrollView(in: child, at: point) { return found }
    }
    return view as? NSScrollView
  }
  override func cancelOperation(_ sender: Any?) {
    if NSApp.modalWindow === self { NSApp.stopModal(withCode: .cancel) } else { orderOut(nil) }
  }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
  override var isOpaque: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
}
