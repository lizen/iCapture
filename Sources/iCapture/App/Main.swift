import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate is a weak reference, so this local variable must hold it until app.run() returns.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
