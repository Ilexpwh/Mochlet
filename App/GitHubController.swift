import Foundation
import Observation
import SlimeCore

@MainActor @Observable final class GitHubController {
    var bindings: [GitHubBinding] = []
    var issues: [GitHubIssue] = []
    var selectedProjectID = ""
    var message: String?
    var busy = false
    var publicationTask: Task<Void, Never>?
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
        let revision = model.composerRevision, selectedTaskID = model.selectedTaskID
        busy = true; message = nil; defer { busy = false }
        do {
            guard model.draft.isEmpty, model.connectedDraft == nil, !model.preparingSubmission else { throw MochletError.message("Clear or send your existing composer draft before preparing an issue prompt.") }
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
            try model.installConnectedDraft(.init(taskID: task.id, projectID: project.id, issue: fresh, binding: binding),
                instruction: "Investigate this issue, implement a fix, and validate the changes in this task workspace.",
                expectedRevision: revision, expectedTaskID: selectedTaskID)
            message = "Task prepared in an isolated workspace for \(project.name), based on its current committed HEAD. Open Companion to review and send. Uncommitted primary-folder changes stay in place."
        } catch { message = error.localizedDescription }
    }
    func validateTask(taskID: String, project: Project?) async throws {
        guard let binding = try await store.githubTaskBinding(taskID: taskID) else { return }
        guard let project, binding.projectID == project.id, let saved = try await store.githubTaskIssue(taskID: taskID) else {
            throw MochletError.message("Issue task no longer matches its project or source.")
        }
        try await GitHubClient.verifyRemote(project: project, repository: binding.repository)
        let fresh = try await GitHubClient(executable: ghPath).issue(saved.number, binding: binding)
        guard fresh.id == saved.id, fresh.updated_at == saved.updated_at, fresh.body == saved.body, fresh.title == saved.title else {
            throw MochletError.message("The GitHub issue changed. Prepare it again to review its latest context before dispatch.")
        }
    }

}
