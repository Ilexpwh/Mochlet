import Foundation
import Observation
import SlimeCore

@MainActor @Observable final class GitHubController {
    var bindings: [GitHubBinding] = []
    var issues: [GitHubIssue] = []
    var selectedProjectID = ""
    var message: String?
    var busy = false
    var ghPath = UserDefaults.standard.string(forKey: "ghPath") ?? "/opt/homebrew/bin/gh" {
        didSet { UserDefaults.standard.set(ghPath, forKey: "ghPath") }
    }
    var binding: GitHubBinding? { bindings.first { $0.projectID == selectedProjectID } }
    private let store: Store
    init(store: Store) { self.store = store }
    func load(projectID: String) async {
        if selectedProjectID != projectID { issues = [] }
        selectedProjectID = projectID
        do {
            let savedBindings = try await store.githubBindings()
            let savedIssues = try await store.githubIssues(projectID: projectID)
            guard selectedProjectID == projectID else { return }
            bindings = savedBindings; issues = savedIssues
        } catch { message = error.localizedDescription }
    }
    func bind(project: Project, slug: String) async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            let binding = try await GitHubClient(executable: ghPath).bind(projectID: project.id, slug: slug)
            try await GitHubClient.verifyRemote(project: project, repository: binding.repository)
            try await store.bindGitHub(binding)
            await load(projectID: project.id)
            message = "Connected as \(binding.account.login). Sync to retrieve issues."
        } catch { message = error.localizedDescription }
    }
    func sync() async {
        guard !busy, let binding else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            let issues = try await GitHubClient(executable: ghPath).issues(binding)
            try await store.replaceGitHubIssues(issues, binding: binding)
            await load(projectID: selectedProjectID)
            message = "Synced \(issues.count) issues."
        } catch { message = error.localizedDescription }
    }
    func prepare(_ issue: GitHubIssue, model: AppModel) async {
        guard !busy, let binding, let project = model.projects.first(where: { $0.id == binding.projectID }) else { return }
        busy = true; message = nil; defer { busy = false }
        do {
            guard model.draft.isEmpty else { throw MochletError.message("Clear or send your existing composer draft before preparing an issue prompt.") }
            try await GitHubClient.verifyRemote(project: project, repository: binding.repository)
            let fresh = try await GitHubClient(executable: ghPath).issue(issue.number, binding: binding)
            guard fresh.id == issue.id else { throw MochletError.message("Issue identity changed. Sync again.") }
            let task = try await store.prepareGitHubTask(fresh, binding: binding)
            guard ![.queued, .running, .waiting].contains(task.state) else { throw MochletError.message("This issue already has queued or active work. Open it in Task history.") }
            let workspace: TaskWorkspace
            if let saved = try await store.workspace(taskID: task.id) { workspace = saved }
            else {
                workspace = try await TaskWorkspaces.plan(task: task, project: project, folder: model.folder)
                try await store.saveWorkspace(workspace)
            }
            try await TaskWorkspaces.materialize(workspace, project: project)
            try await model.refresh()
            guard model.draft.isEmpty else { throw MochletError.message("The issue task is saved. Clear or send your existing composer draft before preparing its prompt.") }
            model.selectedProjectID = project.id; model.selectedTaskID = task.id
            model.draft = fresh.taskPrompt
            message = "Task prepared in an isolated workspace for \(project.name), based on its current committed HEAD. Open Companion to review and send. Uncommitted primary-folder changes stay in place."
        } catch { message = error.localizedDescription }
    }
}
