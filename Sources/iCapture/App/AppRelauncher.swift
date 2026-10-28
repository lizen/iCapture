import AppKit

/// Restarts iCapture so a new UI language takes effect.
@MainActor
enum AppRelauncher {
    /// A helper shell waits until this process has exited, then reopens the app through LaunchServices (`open`).
    /// Launching only after the old process is gone keeps the new copy from failing to register the global hotkey
    /// the old copy still holds. The pid and path are passed as arguments, so paths with spaces need no quoting.
    static func relaunch() {
        let script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]

        do {
            try task.run()
            // Quitting goes through prepareForTermination, which saves pending edits and settings.
            NSApp.terminate(nil)
        } catch {
            // Keep running: the language is already saved and applies at the next launch anyway.
            NSLog("iCapture failed to restart: %@", String(describing: error))
        }
    }
}
