import AppKit
import SwiftUI

final class ScrollSpy: NSScrollView {
    var received = 0
    override func scrollWheel(with event: NSEvent) { received += 1 }
}
@main struct MenuInputTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let panel = GlassMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 620))
        let scroll = ScrollSpy(frame: NSRect(x: 20, y: 40, width: 380, height: 450))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 1400))
        content.addSubview(scroll); panel.contentView = content
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 100, wheel2: 0, wheel3: 0)!
        let event = NSEvent(cgEvent: cg)!
        precondition(panel.routeScroll(event, at: NSPoint(x: 100, y: 200)) && scroll.received == 1)
        precondition(panel.routeScroll(event, at: NSPoint(x: 100, y: 600)) && scroll.received == 1, "Header leaked scroll events")
        precondition(panel.routeScroll(event, at: NSPoint(x: 10, y: 10)) && scroll.received == 1, "Padding leaked scroll events")
        precondition(!panel.routeScroll(event, at: NSPoint(x: -20, y: 200)) && scroll.received == 1, "Panel captured scrolling outside itself")
        precondition(panel.routeScroll(event, at: NSPoint(x: 100, y: 200)) && scroll.received == 2, "Scroll edge events were not contained")
        print("PASS menu input: settings routing, header/padding consumption, repeated wheel events and outside-window exclusion")
    }
}
