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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(projects.projects.isEmpty ? "No projects yet" : "\(projects.projects.count) project\(projects.projects.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer(minLength: 0)
                IslandButton("Add folder…", symbol: "folder.badge.plus") { addFolder() }
                IslandButton("Clone…", symbol: "arrow.down.circle") { showClone.toggle() }
            }
            if let url = projects.pendingOffer {
                OfferRow(name: url.lastPathComponent, path: url.path, app: app)
            }
            if showClone {
                HStack(spacing: 6) {
                    TextField("git@github.com:you/repo.git", text: $cloneURL)
                        .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .onSubmit { startClone() }
                    IslandButton("Clone", symbol: "arrow.down") { startClone() }
                }
            }
            if let status = projects.cloneStatus {
                HStack(spacing: 6) {
                    ProgressView(value: projects.cloneProgress ?? 0).tint(Color(red: 0.5, green: 0.83, blue: 1.0)).frame(width: 120)
                    Text(status).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(projects.projects) { p in
                        ProjectRow(project: p, app: app, taskFor: $taskFor, task: $task, agent: $agent)
                    }
                    if projects.projects.isEmpty, projects.pendingOffer == nil {
                        Text("Drop a folder on me, say “make ~/path a project”, or clone a repo.")
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            if let n = projects.note ?? projects.loadError {
                Text(n).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        app.window.hold("panel", true)
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
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.5, green: 0.83, blue: 1.0))
            VStack(alignment: .leading, spacing: 1) {
                Text("Make “\(name)” a project?").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
            IslandButton("Yes", symbol: "checkmark") { app.projects.acceptOffer() }
            IslandButton("No", symbol: "xmark") { app.projects.declineOffer() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

private struct ProjectRow: View {
    let project: Project
    let app: AppCoordinator
    @Binding var taskFor: String?
    @Binding var task: String
    @Binding var agent: String
    @FocusState private var taskFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(project.name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Text((project.primaryPath ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if let live = app.sessions.live.first(where: { $0.project.isRegistered && $0.project.name == project.name }) {
                    Text(live.agent.glyph + " " + live.state.rawValue).font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(CardStyle.color(live.state)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.1)))
                }
                IslandButton("Work on…", symbol: "play") {
                    taskFor = taskFor == project.slug ? nil : project.slug
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
                    Button("Remove from projects", role: .destructive) { app.projects.remove(project.slug) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.white.opacity(0.7))
            }
            if taskFor == project.slug {
                HStack(spacing: 6) {
                    Picker("", selection: $agent) {
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                        Text("Gemini").tag("gemini")
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    TextField("What should it do?", text: $task)
                        .textFieldStyle(.plain).font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white)
                        .focused($taskFocused)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                        .onSubmit { go() }
                    IslandButton(app.settings.headlessTasks ? "Run here" : "Open terminal", symbol: app.settings.headlessTasks ? "bolt" : "terminal") { go() }
                }
                .onAppear { taskFocused = true; app.window.focusInput() }
            }
        }
        .padding(.vertical, 3)
    }

    private func go() {
        let t = task.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        app.startWork(project: project, task: t, agent: AgentKind(tag: agent, bundleID: nil, termProgram: nil))
        taskFor = nil
        task = ""
    }
}
