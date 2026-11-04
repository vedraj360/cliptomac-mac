import AppKit

@main
struct MainApp {
    static func main() {
        AppTypography.registerFonts()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
