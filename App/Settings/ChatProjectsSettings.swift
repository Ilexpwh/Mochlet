import AppKit
import SwiftUI
import MochletCore

struct ChatSettingsView: View {
    let app: AppCoordinator

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Section("Default backend") {
                Picker("Provider", selection: Binding(get: { app.chat.providerKind }, set: { app.chat.setProvider($0) })) {
                    ForEach(ChatProviderKind.allCases) { k in Text(k.displayName).tag(k) }
                }
                HStack {
                    TextField("Model (empty = the CLI's default)", text: $s.chatModel)
                    if !app.chat.providerKind.isCLI {
                        Menu("Choose") {
                            ForEach(app.chat.models(for: app.chat.providerKind), id: \.self) { m in Button(m) { app.chat.setModel(m) } }
                            Divider()
                            Button("Refresh list") { app.chat.refreshModels(for: app.chat.providerKind) }
                        }
                        .fixedSize()
                    }
                }
                if let e = app.chat.modelListError { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("Claude Code, Codex and Gemini CLI use your subscriptions through the installed command-line tools; the others call an API with a key stored in your login keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("API keys") {
                ForEach(ChatProviderKind.allCases.filter { !$0.isCLI }) { k in
                    ProviderKeyRow(kind: k, app: app)
                }
            }
            Section("Tasks") {
                Toggle("Run “work on <project>” tasks in the background instead of a terminal window", isOn: $s.headlessTasks)
                Text("Background runs appear as mini slimes like any session (Codex: workspace-write sandbox, Claude: accept edits, Gemini: yolo). Terminal windows let you watch and answer the agent yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Attach a screenshot when I drop the slime on a window (needs Screen Recording)", isOn: $s.windowScreenshots)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProviderKeyRow: View {
    let kind: ChatProviderKind
    let app: AppCoordinator
    @State private var key = ""
    @State private var baseURL = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kind.displayName).frame(width: 110, alignment: .leading)
                if kind.needsKey {
                    SecureField(KeychainStore.has(kind.keychainAccount) ? "•••••••• (saved)" : "API key", text: $key)
                        .onSubmit { save() }
                    Button(saved ? "Saved" : "Save") { save() }.disabled(key.isEmpty)
                    if KeychainStore.has(kind.keychainAccount) {
                        Button("Remove") { KeychainStore.delete(kind.keychainAccount); key = ""; saved = false }
                    }
                } else {
                    Text("no key needed").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Base URL").font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                TextField(kind.defaultBaseURL ?? "", text: $baseURL)
                    .font(.caption)
                    .onSubmit { app.settings.setBaseURL(baseURL, for: kind) }
                    .onChange(of: baseURL) { _, v in app.settings.setBaseURL(v, for: kind) }
            }
        }
        .onAppear { baseURL = app.settings.baseURLOverride(for: kind) ?? "" }
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        KeychainStore.set(k, account: kind.keychainAccount)
        key = ""
        saved = true
        app.chat.refreshModels(for: kind)
    }
}

struct ProjectsSettingsView: View {
    let app: AppCoordinator

    var body: some View {
        @Bindable var s = app.settings
        let projects = app.projects!
        Form {
            Section("Opening agents") {
                Picker("Terminal", selection: $s.preferredTerminal) {
                    Text("Automatic (\(projects.preferredTerminal.displayName))").tag("auto")
                    ForEach(ProjectsController.installedTerminals) { t in Text(t.displayName).tag(t.rawValue) }
                }
                Picker("Default agent", selection: $s.defaultAgent) {
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Gemini CLI").tag("gemini")
                }
                LabeledContent("Registry") { Text("~/Mochlet/projects.json").font(.caption).textSelection(.enabled) }
                LabeledContent("Clones go to") { Text("~/Mochlet/Projects/").font(.caption).textSelection(.enabled) }
            }
            Section("Projects") {
                if projects.projects.isEmpty {
                    Text("No projects yet. Drop a folder on the slime, use the Projects card, or say “make ~/path a project”.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(projects.projects) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.body.weight(.medium))
                            Text((p.primaryPath ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !p.lastSessions.isEmpty {
                            Text(p.lastSessions.keys.sorted().joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Remove") { projects.remove(p.slug) }.controlSize(.small)
                    }
                }
                Button("Add folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { projects.add(path: url.path) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
