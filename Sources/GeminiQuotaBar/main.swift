import AppKit

@main
struct GeminiQuotaBarApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // Menu-bar only app (no Dock icon, no app switcher entry)
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

