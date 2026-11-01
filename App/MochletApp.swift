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
    private var shortcutRecording = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mochlet", isDirectory: true)
            #if DEBUG
            if let smokeFolder = ProcessInfo.processInfo.environment["MOCHLET_DATA_DIR"], smokeFolder.hasPrefix("/") {
                folder = URL(fileURLWithPath: smokeFolder, isDirectory: true)
            }
            #endif
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try Store(path: folder.appendingPathComponent("mochlet.sqlite").path)
            let model = AppModel(store: store, folder: folder)
            self.model = model
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(captureInterrupted), name: NSWorkspace.willSleepNotification, object: nil)
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(captureInterrupted), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
            surfaces = SurfaceController(model: model)
            model.shortcuts.start { [weak self] id, down in
                guard let self, let model = self.model else { return }
                if id == 1, down { self.surfaces?.togglePanel() }
                if id == 2 {
                    if down, !model.speech.active, !model.meetings.active {
                        self.surfaces?.openForVoice()
                        model.speech.start(); self.shortcutRecording = model.speech.active
                    } else if !down, self.shortcutRecording {
                        self.shortcutRecording = false; model.speech.stop()
                    }
                }
            }
            Task { await model.load() }
            surfaces?.showWorkspace()
        } catch {
            let alert = NSAlert(); alert.messageText = "Mochlet could not open its data"
            alert.informativeText = error.localizedDescription; alert.runModal()
            NSApp.terminate(nil)
        }
    }
    @objc private func captureInterrupted() {
        shortcutRecording = false
        model?.shortcuts.releaseHeldKeys()
        if model?.speech.active == true { model?.speech.cancel(); model?.speech.message = "Voice command cancelled on lock or sleep. Start a new recording when ready." }
        model?.speech.stopSpeaking()
        Task { await model?.meetings.pause(reason: "Paused on lock or sleep. Resume explicitly.") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.isBusy || model.speech.active || model.meetings.active {
            let alert = NSAlert(); alert.messageText = "Work is still active"
            alert.informativeText = "Quitting interrupts active work, saves meeting segments and discards any voice command in progress. Its history remains available when you return."
            alert.addButton(withTitle: "Keep Mochlet open"); alert.addButton(withTitle: "Quit and interrupt")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        model?.speech.cancel(); model?.speech.stopSpeaking()
        model?.shortcuts.stop()
        Task { [model] in
            await model?.meetings.shutdown()
            if let runtime=model?.runtime {await runtime.client.stop()}
            NSApp.reply(toApplicationShouldTerminate:true)
        }
        return .terminateLater
    }
}
