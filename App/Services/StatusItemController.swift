import AppKit

/// The menu bar item: a way back in when the island is hidden, plus the essentials.
@MainActor
final class StatusItemController: NSObject {
    private var item: NSStatusItem?
    private unowned let app: AppCoordinator

    init(app: AppCoordinator) {
        self.app = app
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Mochlet")
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        self.item = item
    }

    func refresh() {
        item?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Open Mochlet", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Ask…  ⌃⌥Space", action: #selector(ask), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pause = NSMenuItem(title: app.settings.observationPaused ? "Resume observation" : "Pause observation", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let sound = NSMenuItem(title: app.settings.soundEnabled ? "Mute sounds" : "Unmute sounds", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        menu.addItem(sound)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Mochlet", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func open() { app.reveal() }
    @objc private func ask() { app.openAsk() }
    @objc private func togglePause() { app.settings.observationPaused.toggle(); refresh() }
    @objc private func toggleSound() { app.settings.soundEnabled.toggle(); app.applySettings(); refresh() }
    @objc private func settings() { app.openSettings() }
    @objc private func quit() { app.quit() }
}
