import SwiftUI
import AppKit
import SlimeCore

@main struct MochletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var surfaces: SurfaceController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochlet", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try Store(path: folder.appendingPathComponent("mochlet.sqlite").path)
            let model = AppModel(store: store, folder: folder)
            self.model = model
            surfaces = SurfaceController(model: model)
            Task { await model.load() }
            surfaces?.showWorkspace()
        } catch {
            let alert = NSAlert(); alert.messageText = "Mochlet could not open its data"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Work is still active"
        alert.informativeText = "Quitting interrupts active work. Its history remains available when you return."
        alert.addButton(withTitle: "Keep Mochlet open"); alert.addButton(withTitle: "Quit and interrupt")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
