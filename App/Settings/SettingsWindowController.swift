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
        window.contentView = NSHostingView(rootView: SettingsView(app: app, preview: CharacterPreviewModel()))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(tab: String? = nil) {
        if let tab { app.notch.settingsTab = tab }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// PNG of the settings content (debug channel).
    func snapshot() -> Data? {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

struct SettingsView: View {
    let app: AppCoordinator
    let preview: CharacterPreviewModel

    var body: some View {
        TabView(selection: Binding(get: { app.notch.settingsTab }, set: { app.notch.settingsTab = $0 })) {
            GeneralSettingsView(app: app).tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag("general")
            CharacterSettingsView(app: app, preview: preview).tabItem { Label("Character", systemImage: "face.smiling") }.tag("character")
            AgentsSettingsView(app: app).tabItem { Label("Agents", systemImage: "terminal") }.tag("agents")
            ChatSettingsView(app: app).tabItem { Label("Chat", systemImage: "bubble.left") }.tag("chat")
            ProjectsSettingsView(app: app).tabItem { Label("Projects", systemImage: "folder") }.tag("projects")
            KnowledgeSettingsView(app: app).tabItem { Label("Knowledge", systemImage: "books.vertical") }.tag("knowledge")
            VoiceSettingsView(app: app).tabItem { Label("Voice & Meetings", systemImage: "waveform") }.tag("voice")
            SignalsSettingsView(app: app).tabItem { Label("Signals", systemImage: "antenna.radiowaves.left.and.right") }.tag("signals")
        }
        .frame(width: 620, height: 500)
        .padding()
    }
}

struct AgentsSettingsView: View {
    let app: AppCoordinator

    var body: some View {
        Form {
            hooksSection
            cardsSection
            statusSection
        }
        .formStyle(.grouped)
        .onAppear { app.installers.refresh() }
        .sheet(item: Binding(get: { app.installers.preview }, set: { if $0 == nil { app.installers.cancelPreview() } })) { p in
            InstallPreviewSheet(app: app, preview: p)
        }
    }

    private var homePath: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private var hooksSection: some View {
        let inst = app.installers!
        return Section {
            ForEach(inst.rows) { row in
                AgentRow(app: app, row: row)
            }
            if let m = inst.lastMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Hooks")
        } footer: {
            Text("Mochlet watches your real sessions through each agent's hook system. Installing shows the whole new file first and keeps a dated backup. The relay is \(inst.relayPath.replacingOccurrences(of: homePath, with: "~")).")
        }
    }

    private var cardsSection: some View {
        @Bindable var s = app.settings
        return Section("Cards") {
            Toggle("Answer approvals and questions from the notch for terminal sessions", isOn: $s.terminalCardsEnabled)
            Toggle("Show the Claude plan pill", isOn: $s.showClaudePlan)
            Toggle("Show the Codex plan pill", isOn: $s.showCodexPlan)
                .onChange(of: s.showCodexPlan) { _, on in if on { app.plans.refreshCodex(force: true) } }
            HStack {
                Slider(value: $s.finishedLinger, in: 2...30, step: 1) { Text("Finished slimes linger") }
                Text("\(Int(s.finishedLinger)) s").monospacedDigit().frame(width: 36)
            }
            Toggle("Pause observation", isOn: Binding(get: { s.observationPaused }, set: { _ in app.menu(.pauseObservation) }))
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Socket") {
                Text(app.hooks.isRunning ? "listening" : (app.hooks.lastError ?? "stopped")).font(.caption).foregroundStyle(app.hooks.isRunning ? Color.secondary : Color.red)
            }
            LabeledContent("Events received") { Text("\(app.sessions.eventCount)").font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Live sessions") { Text("\(app.sessions.live.count)").font(.caption).foregroundStyle(.secondary) }
            LabeledContent("Other agents") {
                Text("Antigravity, Copilot, Muse, OpenCode, Amp, Hermes and any agent that can run a command: see docs/AGENTS.md. Cursor and Claude Desktop ride on the Claude Code hooks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AgentRow: View {
    let app: AppCoordinator
    let row: AgentInstallerController.Row

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.agent.kind.displayName).font(.body.weight(.semibold))
                    StatusChip(status: row.status)
                    if !row.cliFound { Text("CLI not found").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(row.agent.file.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let n = row.note { Text(n).font(.caption).foregroundStyle(n.hasPrefix("Run /hooks") || n.hasPrefix("A file of yours") ? Color.orange : Color.secondary) }
                if let e = row.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var buttons: some View {
        switch row.status {
        case .notInstalled:
            Button("Install…") { app.installers.prepareInstall(row.agent) }
        case .outdated:
            Button("Update…") { app.installers.prepareInstall(row.agent) }
            Button("Remove") { app.installers.uninstall(row.agent) }
        case .installed:
            Button("Remove") { app.installers.uninstall(row.agent) }
        }
    }
}

struct StatusChip: View {
    let status: HookInstallStatus

    var body: some View {
        let text: String
        let color: Color
        switch status {
        case .installed: text = "installed"; color = .green
        case .outdated: text = "update available"; color = .orange
        case .notInstalled: text = "not installed"; color = .secondary
        }
        return Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(color.opacity(0.15)))
    }
}

struct InstallPreviewSheet: View {
    let app: AppCoordinator
    let preview: AgentInstallerController.Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install Mochlet hooks for \(preview.agent.kind.displayName)").font(.title3.weight(.semibold))
            Text("This is the whole file Mochlet will write to \(preview.path.path). The current file is backed up next to it first.").font(.caption).foregroundStyle(.secondary)
            if preview.previousStatusLine != nil {
                Text("Your existing statusLine command keeps running: Mochlet's relay forwards the plan usage and then runs it unchanged.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Before").font(.caption.weight(.semibold))
                    ScrollView { Text(preview.before).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("After").font(.caption.weight(.semibold))
                    ScrollView { Text(preview.after).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { app.installers.cancelPreview() }.keyboardShortcut(.cancelAction)
                Button("Write file") { app.installers.confirmInstall() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 520)
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
                Picker("Position", selection: Binding(get: { app.window.currentAnchor.storageValue },
                                                      set: { app.window.setAnchor(IslandAnchor(storageValue: $0)) })) {
                    ForEach(IslandAnchor.presets, id: \.storageValue) { a in
                        Text(a.title(hasNotch: app.notch.geometry.hasNotch)).tag(a.storageValue)
                    }
                    if app.window.currentAnchor.isCustom {
                        Text("Custom (where you dragged it)").tag(app.window.currentAnchor.storageValue)
                    }
                }
                Text("Drag the black strip, or ⌘-drag anywhere on the island, to move it along the top edge. Each screen remembers its own spot.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open when the pointer rests on it", isOn: $s.openOnHover)
                    .onChange(of: s.openOnHover) { _, _ in app.applySettings() }
                HStack {
                    Slider(value: $s.autoCloseSeconds, in: 5...60, step: 5) { Text("Close after") }
                        .onChange(of: s.autoCloseSeconds) { _, _ in app.applySettings() }
                    Text("\(Int(s.autoCloseSeconds)) s").monospacedDigit().frame(width: 36)
                }
                Toggle("Greet me when Mochlet starts", isOn: $s.greetOnLaunch)
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
                    HStack(spacing: 8) {
                        Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["MochletGitHash"] as? String ?? "dev"))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("What's new") { app.openWhatsNew() }.controlSize(.small)
                    }
                }
            }
            PermissionsSection(app: app)
            DiagnosticsSection(app: app)
        }
        .formStyle(.grouped)
        .onAppear { app.permissions.refresh() }
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
