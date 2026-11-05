import AppKit
import Observation
import MochletCore

/// `~/Mochlet/projects.json`: the registry, folder offers, cloning and opening agents in a terminal.
@MainActor
@Observable
final class ProjectsController {
    private(set) var file = ProjectsFile()
    private(set) var loadError: String?
    private(set) var cloneProgress: Double?
    private(set) var cloneStatus: String?
    /// A dropped folder waiting for "Make this a project?".
    var pendingOffer: URL?
    /// Last message for the projects card ("Opened Mochlet in iTerm").
    private(set) var note: String?
    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var lastWrite: (size: Int, mtime: Date)?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var cloneProcess: Process?

    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochlet", isDirectory: true) }
    static var fileURL: URL { root.appendingPathComponent("projects.json") }
    static var cloneRoot: URL { root.appendingPathComponent("Projects", isDirectory: true) }

    init(app: AppCoordinator) { self.app = app }

    var projects: [Project] { file.active }

    func start() {
        load()
        watch()
    }

    func load() {
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: Self.fileURL) {
                file = try ProjectsFile.decode(data)
            } else {
                file = ProjectsFile()
            }
            loadError = nil
        } catch {
            loadError = "projects.json: \(error.localizedDescription)"
        }
        app.sessions.setProjects(file.projects)
    }

    private func save() {
        do {
            let data = try file.encode()
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try data.write(to: Self.fileURL, options: .atomic)
            let attrs = try FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
            lastWrite = (data.count, attrs[.modificationDate] as? Date ?? Date())
            watch()
        } catch {
            loadError = "Could not save projects.json: \(error.localizedDescription)"
        }
        app.sessions.setProjects(file.projects)
    }

    /// Reloads when the user edits the file by hand (our own writes are recognised by size + mtime).
    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = Darwin.open(Self.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let attrs = try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)
                if let attrs, let size = attrs[.size] as? Int, let m = attrs[.modificationDate] as? Date,
                   let lw = self.lastWrite, lw.size == size, abs(lw.mtime.timeIntervalSince(m)) < 0.01 { return }
                // Mid-rename (an atomic write, ours or an editor's): wait for the new file.
                if attrs == nil, src.data.contains(.delete) || src.data.contains(.rename) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if FileManager.default.fileExists(atPath: Self.fileURL.path) { self.load() }
                            self.watch()
                        }
                    }
                    return
                }
                self.load()
                if src.data.contains(.delete) || src.data.contains(.rename) { self.watch() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    // MARK: Registry

    @discardableResult
    func add(path: String, name: String? = nil, repo: String? = nil, defaultAgent: String? = nil, trusted: Bool = true) -> Project {
        let normalized = ProjectResolver.normalize(path)
        if let existing = file.projects.first(where: { $0.paths.contains(where: { ProjectResolver.normalize($0) == normalized }) }) {
            var p = existing
            if p.archived { p.archived = false }
            if let name, !name.isEmpty { p.name = name }
            update(p)
            return p
        }
        let displayName = (name?.isEmpty == false ? name! : (normalized as NSString).lastPathComponent)
        let slug = Slug.unique(Slug.make(displayName), taken: Set(file.projects.map(\.slug)))
        let gitRepo = repo ?? Self.gitRemote(at: normalized)
        let underCloneRoot = normalized.hasPrefix(ProjectResolver.normalize(Self.cloneRoot.path) + "/")
        let p = Project(slug: slug, name: displayName, paths: [normalized], repo: gitRepo, defaultAgent: defaultAgent, trusted: trusted && !underCloneRoot)
        file.projects.append(p)
        save()
        note = "Added \(displayName)."
        return p
    }

    func update(_ p: Project) {
        if let i = file.projects.firstIndex(where: { $0.slug == p.slug }) { file.projects[i] = p } else { file.projects.append(p) }
        save()
    }

    func setTrusted(_ slug: String, _ trusted: Bool) {
        guard var p = file.project(slug: slug) else { return }
        p.trusted = trusted
        update(p)
    }

    func remove(_ slug: String) {
        file.projects.removeAll { $0.slug == slug }
        save()
    }

    func project(_ slug: String?) -> Project? { slug.flatMap { file.project(slug: $0) } }

    func match(_ query: String) -> Project? { ProjectMatcher.match(query, in: file.projects) }

    /// Remember the last session per agent so "Resume <project>" works.
    func recordSession(agent: AgentKind, sessionID: String, cwd: String? = nil, projectSlug: String? = nil) {
        guard !sessionID.isEmpty, !sessionID.hasPrefix("headless-") else { return }
        let slug = projectSlug ?? cwd.flatMap { ProjectResolver.project(containing: $0, in: file.projects)?.slug }
        guard let slug, var p = file.project(slug: slug) else { return }
        if p.lastSessions[agent.id] == sessionID { return }
        p.lastSessions[agent.id] = sessionID
        if let i = file.projects.firstIndex(where: { $0.slug == slug }) { file.projects[i] = p }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    static func gitRemote(at path: String) -> String? {
        let config = "\(path)/.git/config"
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return nil }
        var inOrigin = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]" }
            else if inOrigin, line.hasPrefix("url") { return line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: Folder offers

    func offer(folder url: URL) {
        if let existing = ProjectResolver.project(containing: url.path, in: file.projects), ProjectResolver.normalize(existing.primaryPath ?? "") == ProjectResolver.normalize(url.path) {
            note = "\(existing.name) is already a project."
            pendingOffer = nil
            return
        }
        pendingOffer = url
    }

    func acceptOffer() {
        guard let url = pendingOffer else { return }
        pendingOffer = nil
        let p = add(path: url.path)
        app.slime.stage.main.trigger(.happy)
        note = "\(p.name) is now a project."
    }

    func declineOffer() {
        pendingOffer = nil
    }

    // MARK: Clone

    func clone(url: String, name: String?) {
        guard cloneProcess == nil else { note = "A clone is already running."; return }
        guard let git = CLIBinaries.find("git") else { note = "git is not installed."; return }
        let base = (url.split(separator: "/").last.map(String.init) ?? "repo").replacingOccurrences(of: ".git", with: "")
        let folder = name?.isEmpty == false ? name! : base
        let dest = Self.cloneRoot.appendingPathComponent(folder)
        if FileManager.default.fileExists(atPath: dest.path) {
            add(path: dest.path, name: name, repo: url, trusted: false)
            note = "\(folder) already exists; registered it (untrusted until you say so)."
            return
        }
        try? FileManager.default.createDirectory(at: Self.cloneRoot, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["clone", "--progress", url, dest.path]
        p.environment = CLIBinaries.environment(extra: ["GIT_TERMINAL_PROMPT": "0"])
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        cloneProgress = 0
        cloneStatus = "Cloning \(base)…"
        app.slime.stage.main.startChewing()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppCoordinator.shared.projects.cloneOutput(text) }
            }
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppCoordinator.shared.projects.cloneFinished(status: proc.terminationStatus, url: url, name: name, dest: dest) }
            }
        }
        do {
            try p.run()
            cloneProcess = p
        } catch {
            cloneProgress = nil
            cloneStatus = nil
            app.slime.stage.main.ingestionFinished(success: false)
            note = "Could not start git: \(error.localizedDescription)"
        }
    }

    private func cloneOutput(_ text: String) {
        for line in text.components(separatedBy: CharacterSet(charactersIn: "\r\n")) {
            guard let pct = line.range(of: #"(\d+)%"#, options: .regularExpression) else { continue }
            let n = Double(line[pct].dropLast()) ?? 0
            let phase: Double
            if line.hasPrefix("Receiving") { phase = 0.1 + n / 100 * 0.7 }
            else if line.hasPrefix("Resolving") { phase = 0.8 + n / 100 * 0.2 }
            else { phase = n / 100 * 0.1 }
            cloneProgress = max(cloneProgress ?? 0, phase)
            app.notch.chewProgress = cloneProgress
        }
    }

    private func cloneFinished(status: Int32, url: String, name: String?, dest: URL) {
        cloneProcess = nil
        cloneProgress = nil
        app.notch.chewProgress = nil
        if status == 0 {
            let p = add(path: dest.path, name: name, repo: url, trusted: false)
            cloneStatus = nil
            note = "Cloned \(p.name). Background runs stay off until you trust it."
            app.slime.stage.main.ingestionFinished(success: true)
            app.toast("Cloned \(p.name) into ~/Mochlet/Projects.", symbol: "arrow.down.circle")
        } else {
            cloneStatus = nil
            note = "git clone failed (\(status))."
            app.slime.stage.main.ingestionFinished(success: false)
            app.toast("Clone failed. Check the URL and your SSH keys.", symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Launching agents

    /// Installed terminals, in preference order.
    static var installedTerminals: [TerminalApp] {
        TerminalApp.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil || ($0.binary.flatMap(CLIBinaries.find) != nil) }
    }

    var preferredTerminal: TerminalApp {
        if let t = TerminalApp(rawValue: app.settings.preferredTerminal), Self.installedTerminals.contains(t) { return t }
        let order: [TerminalApp] = [.iterm, .ghostty, .warp, .kitty, .wezterm, .alacritty, .terminal]
        return order.first { Self.installedTerminals.contains($0) } ?? .terminal
    }

    /// Opens a new terminal window in the project running the agent.
    @discardableResult
    func launch(project: Project, agent: AgentKind, task: String?, resume: String?, terminal: TerminalApp? = nil) -> Bool {
        guard let cwd = project.primaryPath else { note = "\(project.name) has no folder."; return false }
        let launch = AgentLaunch(agent: agent, task: task, resume: resume)
        let term = terminal ?? preferredTerminal
        let steps = TerminalLaunchPlanner.plan(terminal: term, cwd: cwd, command: launch.commandLine, title: project.name)
        let ok = execute(steps)
        note = ok ? "Opened \(project.name) in \(term.displayName) with \(agent.displayName)." : "Could not open \(term.displayName)."
        if ok { app.slime.stage.main.trigger(.happy) }
        return ok
    }

    /// Opens the folder in an editor or terminal without running an agent.
    @discardableResult
    func open(project: Project, in target: String?) -> Bool {
        guard let cwd = project.primaryPath else { return false }
        switch target {
        case "cursor":
            return run("/usr/bin/open", ["-b", AgentKind.cursorBundleID, cwd])
        case "vscode":
            return run("/usr/bin/open", ["-b", "com.microsoft.VSCode", cwd])
        default:
            let term = target.flatMap { TerminalApp(rawValue: $0) } ?? preferredTerminal
            let steps = TerminalLaunchPlanner.plan(terminal: term, cwd: cwd, command: "pwd", title: project.name)
            return execute(steps)
        }
    }

    private func execute(_ steps: [LaunchStep]) -> Bool {
        for step in steps {
            switch step {
            case .appleScript(let source, _):
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&error)
                if let error { MochletLogger(category: "projects").error("launch applescript: \(error)"); return false }
            case .open(let args):
                if !run("/usr/bin/open", args) { return false }
            case .command(let name, let args):
                guard let bin = CLIBinaries.find(name) else { return false }
                if !run(bin, args) { return false }
            case .writeFile(let path, let contents):
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                } catch { return false }
            }
        }
        return true
    }

    private func run(_ bin: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = CLIBinaries.environment()
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        return true
    }
}
