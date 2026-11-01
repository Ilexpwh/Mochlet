import SwiftUI
import AppKit
import SlimeCore

@MainActor @Observable final class AppModel {
    let store: Store
    let folder: URL
    var projects: [Project] = []
    var tasks: [WorkTask] = []
    var selectedProjectID = ""
    var selectedTaskID: String?
    var draft = ""
    var errorMessage: String?
    var isBusy = false
    var status = "Ready when you are"
    var slimeName: String { didSet { UserDefaults.standard.set(slimeName, forKey: "slimeName") } }
    var palette: String { didSet { UserDefaults.standard.set(palette, forKey: "palette") } }
    var selectedProject: Project? { projects.first { $0.id == selectedProjectID } }
    var selectedTask: WorkTask? { tasks.first { $0.id == selectedTaskID } }
    var tint: Color { switch palette { case "Peach": .orange; case "Sky": .cyan; case "Lilac": .purple; default: .mint } }
    init(store: Store, folder: URL) {
        self.store = store; self.folder = folder
        slimeName = UserDefaults.standard.string(forKey: "slimeName") ?? "Mochlet"
        palette = UserDefaults.standard.string(forKey: "palette") ?? "Mint"
    }
    func load() async {
        do {
            try await store.recover()
            try await refresh()
            selectedProjectID = projects.first?.id ?? ""
        } catch { report(error) }
    }
    func refresh() async throws { projects = try await store.projects(); tasks = try await store.tasks() }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
    func addProject() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.message = "Choose the working folder for a project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                if let existing = projects.first(where: { $0.root == url.resolvingSymlinksInPath().path }) { selectedProjectID = existing.id; return }
                let project = Project(name: url.lastPathComponent, root: url.path)
                try await store.save(project); try await refresh(); selectedProjectID = project.id
            } catch { report(error) }
        }
    }
    func submit() {
        guard let project = selectedProject, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let prompt = draft; draft = ""
        Task {
            do {
                try ProjectResolver.validateRoot(project)
                let task = WorkTask(projectID: project.id, title: prompt)
                try await store.save(task); try await refresh(); selectedTaskID = task.id
            } catch { draft = prompt; report(error) }
        }
    }
    func shutdown() {}
}
