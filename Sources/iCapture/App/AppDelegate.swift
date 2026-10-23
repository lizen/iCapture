import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator(settings: AppSettings(), history: HistoryStore(), keychain: KeychainStore())
        coordinator.start()
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.prepareForTermination()
    }
}
