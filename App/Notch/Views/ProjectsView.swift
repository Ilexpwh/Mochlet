import AppKit
import SwiftUI
import MochletCore

/// Projects card: the registry, "work on", resume, open, add, clone, and folder offers.
struct ProjectsView: View {
    let app: AppCoordinator
    @State private var cloneURL = ""
    @State private var showClone = false
    @State private var taskFor: String?
    @State private var task = ""
    @State private var agent = "claude"

    var body: some View {
        let projects = app.projects!
        let store = app.notch
        let listMax = CGFloat(max(80, store.contentMaxHeight(for: .projects) - 26 - 8 - (showClone ? 39 : 0) - (projects.pendingOffer == nil ? 0 : 48)))
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "folder", title: projects.projects.isEmpty ? "No projects yet" : "\(projects.projects.count) project\(projects.projects.count == 1 ? "" : "s")", app: app) {
                IconButton("folder.badge.plus", help: "Add a folder…", size: 24) { addFolder() }
                IconButton("arrow.down.circle", help: "Clone a repository…", size: 24, tint: showClone ? IslandStyle.ink : nil) { showClone.toggle() }
            }
            if let url = projects.pendingOffer {
                OfferRow(name: url.lastPathComponent, path: url.path, app: app)
            }
            if showClone {
                HStack(spacing: 6) {
                    TextField("", text: $cloneURL, prompt: fieldPrompt("git@github.com:you/repo.git"))
                        .onSubmit { startClone() }
                        .islandField(size: 12, mono: true)
                    IslandButton("Clone", symbol: "arrow.down", role: .primary, keycap: "⏎") { startClone() }
                }
            }
            if let status = projects.cloneStatus {
                HStack(spacing: 8) {
                    ProgressBar(value: projects.cloneProgress ?? 0, tint: IslandStyle.working).frame(width: 120)
                    Text(status).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2).lineLimit(1)
                }
            }
            if projects.projects.isEmpty, projects.pendingOffer == nil {
                EmptyState(symbol: "folder.badge.plus", line: "No projects yet.", hint: "Drop a folder on me, say “make ~/path a project”, or clone a repo.")
            } else {
                FadeScroll(maxHeight: listMax) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(projects.projects) { p in
                            ProjectRow(project: p, app: app, taskFor: $taskFor, task: $task, agent: $agent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let n = projects.note ?? projects.loadError {
                Text(n).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .projects)
        .onAppear {
            agent = app.settings.defaultAgent
            if app.notch.projectsFocus == "new", let p = projects.projects.first { taskFor = p.slug }
            app.notch.projectsFocus = nil
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add project"
        app.window.hold("panel", true, scope: .view(.projects))
        NSApp.activate()
        panel.begin { resp in
            MainActor.assumeIsolated {
                AppCoordinator.shared.window.hold("panel", false)
                if resp == .OK, let url = panel.url { AppCoordinator.shared.projects.add(path: url.path) }
            }
        }
    }

    private func startClone() {
        let url = cloneURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        app.projects.clone(url: url, name: nil)
        cloneURL = ""
        showClone = false
    }
}

private struct OfferRow: View {
    let name: String
    let path: String
    let app: AppCoordinator

    var body: some View {
        RowBox {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(IslandStyle.working)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make “\(name)” a project?").font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink)
                    PathText(path: path)
                }
                Spacer(minLength: 8)
                IslandButton("Yes", symbol: "checkmark", role: .primary, keycap: "⏎") { app.projects.acceptOffer() }
                IslandButton("No", symbol: "xmark", role: .quiet) { app.projects.declineOffer() }
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project
    let app: AppCoordinator
    @Binding var taskFor: String?
    @Binding var task: String
    @Binding var agent: String
    @FocusState private var taskFocused: Bool
    @State private var hovering = false

    var body: some View {
        let active = taskFor == project.slug
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(project.name).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineLimit(1).layoutPriority(1)
                PathText(path: project.primaryPath ?? "")
                Spacer(minLength: 8)
                if let live = app.sessions.live.first(where: { $0.project.isRegistered && $0.project.name == project.name }) {
                    Chip(text: live.agent.glyph + " " + IslandStyle.label(live.state), tint: IslandStyle.color(live.state))
                }
                IslandButton("Work on…", symbol: "play", role: active ? .secondary : .primary) {
                    taskFor = active ? nil : project.slug
                    task = ""
                }
                if !project.lastSessions.isEmpty {
                    IslandButton("Resume", symbol: "arrow.counterclockwise") { app.resumeProject(project, agent: nil) }
                }
                Menu {
                    ForEach(ProjectsController.installedTerminals) { t in Button("Open in \(t.displayName)") { app.projects.open(project: project, in: t.rawValue) } }
                    Button("Open in Cursor") { app.projects.open(project: project, in: "cursor") }
                    Button("Open in VS Code") { app.projects.open(project: project, in: "vscode") }
                    Button("Show in Finder") { if let p = project.primaryPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } }
                    Divider()
                    Button(project.trusted ? "Untrust (no background runs)" : "Trust for background runs") { app.projects.setTrusted(project.slug, !project.trusted) }
                    Button("Remove from projects", role: .destructive) { app.projects.remove(project.slug) }
                } label: {
                    MenuIconLabel(symbol: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Open in…, trust, remove")
            }
            if active {
                HStack(spacing: 6) {
                    Picker("", selection: $agent) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Gemini").tag("gemini")
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    TextField("", text: $task, prompt: fieldPrompt("What should it do?"))
                        .focused($taskFocused)
                        .onSubmit { go() }
                        .islandField(focused: taskFocused, size: 12)
                    IslandButton(app.settings.headlessTasks && project.trusted ? "Run here" : "Open terminal",
                                 symbol: app.settings.headlessTasks && project.trusted ? "bolt" : "terminal", role: .primary, keycap: "⏎") { go() }
                }
                .onAppear { taskFocused = true; app.window.focusInput() }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: IslandStyle.rowRadius, style: .continuous).fill(active ? IslandStyle.fillHover : hovering ? IslandStyle.fill : Color.clear))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func go() {
        let t = task.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        app.startWork(project: project, task: t, agent: AgentKind(tag: agent, bundleID: nil, termProgram: nil))
        taskFor = nil
        task = ""
    }
}
