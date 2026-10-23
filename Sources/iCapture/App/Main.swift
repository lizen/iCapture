import AppKit

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // NSApplication.delegate는 약한 참조라서, app.run()이 끝날 때까지 이 지역 변수가 붙잡고 있어야 한다.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
