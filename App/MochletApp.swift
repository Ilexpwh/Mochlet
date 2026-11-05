import AppKit

@main
enum MochletMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.meetings?.shutdown()
        AppCoordinator.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppCoordinator.shared.reveal()
        return false
    }

    /// `mochlet://` links: `mochlet://debug/...` drives the app from the command line in debug builds.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            #if DEBUG
            if url.host == "debug" {
                DebugCommands.run(url, app: AppCoordinator.shared)
                continue
            }
            #endif
            AppCoordinator.shared.reveal()
        }
    }
}
