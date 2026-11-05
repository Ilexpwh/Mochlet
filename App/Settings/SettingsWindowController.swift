import AppKit
import SwiftUI
import SlimeKit
import MochletCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private unowned let app: AppCoordinator

    init(app: AppCoordinator) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mochlet Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(app: app))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    let app: AppCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(app: app).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ComingView(title: "Agents", text: "Hook installers for Claude Code, Codex, Gemini and friends arrive with milestone 4.")
                .tabItem { Label("Agents", systemImage: "terminal") }
            ComingView(title: "Chat", text: "Providers, API keys and CLI subscriptions arrive with milestone 5.")
                .tabItem { Label("Chat", systemImage: "bubble.left") }
            ComingView(title: "Projects", text: "The project registry arrives with milestone 5.")
                .tabItem { Label("Projects", systemImage: "folder") }
            ComingView(title: "Knowledge", text: "The OKF knowledge base and its MCP server arrive with milestone 6.")
                .tabItem { Label("Knowledge", systemImage: "books.vertical") }
            ComingView(title: "Voice & Meetings", text: "Speech, the decision engine and the note-taker arrive with milestones 8 and 9.")
                .tabItem { Label("Voice & Meetings", systemImage: "waveform") }
            ComingView(title: "Signals", text: "The AI signals engine arrives with milestone 10.")
                .tabItem { Label("Signals", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .frame(width: 560, height: 440)
        .padding()
    }
}

struct GeneralSettingsView: View {
    let app: AppCoordinator

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Section("Island") {
                Picker("Screen", selection: Binding(get: { s.displayChoice.storageValue }, set: { s.displayChoice = DisplayChoice(storageValue: $0); app.applySettings() })) {
                    Text("Screen with the notch").tag("notch")
                    Text("Menu bar screen").tag("menuBar")
                    Text("Follow the mouse").tag("followMouse")
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in
                        if let uuid = NotchWindowController.displayUUID(screen) {
                            Text(screen.localizedName).tag("display:\(uuid)")
                        }
                    }
                }
                Toggle("Open when the pointer rests on it", isOn: $s.openOnHover)
                    .onChange(of: s.openOnHover) { _, _ in app.applySettings() }
                HStack {
                    Slider(value: $s.autoCloseSeconds, in: 5...60, step: 5) { Text("Close after") }
                        .onChange(of: s.autoCloseSeconds) { _, _ in app.applySettings() }
                    Text("\(Int(s.autoCloseSeconds)) s").monospacedDigit().frame(width: 36)
                }
                Toggle("Greet me when Mochlet starts", isOn: $s.greetOnLaunch)
            }
            Section("Character") {
                Picker("Colour", selection: $s.themeName) {
                    ForEach(SlimeTheme.names, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .onChange(of: s.themeName) { _, _ in app.applySettings() }
                Toggle("Sounds", isOn: $s.soundEnabled).onChange(of: s.soundEnabled) { _, _ in app.applySettings() }
                HStack {
                    Slider(value: $s.soundVolume, in: 0...1) { Text("Volume") }
                        .onChange(of: s.soundVolume) { _, _ in app.applySettings() }
                    Button("Test") { app.slime.sound.play(SoundCue(.greet)) }
                }
                Picker("Motion", selection: Binding(get: { s.reduceMotionOverride.map { $0 ? "on" : "off" } ?? "system" },
                                                    set: { s.reduceMotionOverride = $0 == "system" ? nil : ($0 == "on"); app.applySettings() })) {
                    Text("Follow system Reduce Motion").tag("system")
                    Text("Full motion").tag("off")
                    Text("Reduced motion").tag("on")
                }
                Stepper("Visible mini slimes: \(s.maxVisibleMinis)", value: $s.maxVisibleMinis, in: 2...6)
                    .onChange(of: s.maxVisibleMinis) { _, _ in app.applySettings() }
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 }))
                if s.launchAtLoginNeedsApproval {
                    Text("Approve Mochlet under System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Global shortcuts (⌃⌥Space ask · ⌃⌥V hold to talk · ⌃⌥T terminal · ⌃⌥A alert)", isOn: $s.hotkeysEnabled)
                    .onChange(of: s.hotkeysEnabled) { _, _ in app.applySettings() }
                ForEach(HotKeyCenter.shared.conflicts, id: \.self) { c in
                    Text(c).font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Sound overrides") {
                    Text("~/Library/Application Support/Mochlet/Sounds/<name>.wav").font(.caption).textSelection(.enabled)
                }
                LabeledContent("Version") {
                    Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["MochletGitHash"] as? String ?? "dev"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ComingView: View {
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
