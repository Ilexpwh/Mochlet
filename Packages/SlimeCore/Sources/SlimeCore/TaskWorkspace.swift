import Foundation

public struct TaskWorkspace: Codable, Sendable, Equatable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let projectID: String
    public let root: String
    public let commonDirectory: String
    public let baseCommit: String
    public let branch: String
}

public enum TaskWorkspaces {
    static func git(_ arguments: [String], at root: String) async throws -> String {
        let output = try await CommandProcess().run(executable: "/usr/bin/git", arguments: ["--no-optional-locks", "-c", "core.hooksPath=/dev/null"] + arguments, cwd: root)
        guard output.status == 0 else { throw MochletError.message("Git \(arguments.first ?? "operation") failed (exit \(output.status)). No existing files were reset.") }
        return String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func plan(task: WorkTask, project: Project, folder: URL) async throws -> TaskWorkspace {
        try ProjectResolver.validateRoot(project)
        guard task.projectID == project.id, UUID(uuidString: task.id) != nil, task.threadID == nil else {
            throw MochletError.message("A new workspace requires an unstarted task in this project.")
        }
        let actual = try await git(["rev-parse", "--show-toplevel"], at: project.root)
        guard URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == project.root else {
            throw MochletError.message("Register the repository root, not one of its subfolders, for isolated issue work.")
        }
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: project.root)
        let base = try await git(["rev-parse", "--verify", "HEAD^{commit}"], at: project.root)
        let directory = folder.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return TaskWorkspace(taskID: task.id, projectID: project.id, root: directory.appendingPathComponent(task.id).path,
            commonDirectory: URL(fileURLWithPath: common).resolvingSymlinksInPath().path,
            baseCommit: base, branch: "mochlet/task-" + task.id.lowercased())
    }
    public static func materialize(_ workspace: TaskWorkspace, project: Project) async throws {
        guard workspace.projectID == project.id else { throw MochletError.message("Workspace project mismatch.") }
        if !FileManager.default.fileExists(atPath: workspace.root) {
            _ = try await git(["worktree", "add", "-b", workspace.branch, "--", workspace.root, workspace.baseCommit], at: project.root)
        }
        try await validate(workspace, project: project)
    }
    public static func validate(_ workspace: TaskWorkspace, project: Project) async throws {
        guard workspace.projectID == project.id else { throw MochletError.message("Workspace project mismatch.") }
        let primaryCommon = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: project.root)
        let common = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: workspace.root)
        let actual = try await git(["rev-parse", "--show-toplevel"], at: workspace.root)
        guard URL(fileURLWithPath: primaryCommon).resolvingSymlinksInPath().path == workspace.commonDirectory,
              URL(fileURLWithPath: common).resolvingSymlinksInPath().path == workspace.commonDirectory,
              URL(fileURLWithPath: actual).resolvingSymlinksInPath().path == workspace.root else {
            throw MochletError.message("Workspace repository or location changed. Dispatch stopped to protect project routing.")
        }
    }
    public static func review(_ workspace: TaskWorkspace, project: Project) async throws -> String {
        try await validate(workspace, project: project)
        let status = try await git(["status", "--short", "--untracked-files=normal"], at: workspace.root)
        let diff = try await git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", workspace.baseCommit, "--"], at: workspace.root)
        return "Workspace: \(workspace.root)\nBase: \(workspace.baseCommit)\n\nStatus (includes untracked files):\n\(status.isEmpty ? "Clean" : status)\n\nTracked changes from base (untracked file contents are not included):\n\(diff.isEmpty ? "No tracked changes" : diff)"
    }
}

extension TaskWorkspaces {
    static func publicationHead(_ workspace: TaskWorkspace, project: Project) async throws -> String {
        try await validate(workspace, project: project)
        guard workspace.branch == "mochlet/task-" + workspace.taskID.lowercased(), UUID(uuidString: workspace.taskID) != nil,
              try await git(["symbolic-ref", "--short", "HEAD"], at: workspace.root) == workspace.branch else {
            throw MochletError.message("The workspace is no longer on its saved task branch.")
        }
        guard try await git(["status", "--porcelain=v1", "--untracked-files=all"], at: workspace.root).isEmpty else {
            throw MochletError.message("Commit or remove the task workspace's pending changes before preparing a PR. The preview publishes committed content only.")
        }
        let head = try await git(["rev-parse", "--verify", "HEAD^{commit}"], at: workspace.root)
        guard PullRequestAPI.validSHA(head), PullRequestAPI.validSHA(workspace.baseCommit) else { throw MochletError.message("Invalid task commit.") }
        _ = try await git(["merge-base", "--is-ancestor", workspace.baseCommit, head], at: workspace.root)
        return head
    }
    public static func publicationReview(_ workspace: TaskWorkspace, project: Project, baseSHA: String) async throws -> (String, String) {
        guard PullRequestAPI.validSHA(baseSHA) else { throw MochletError.message("Invalid target commit.") }
        let head = try await publicationHead(workspace, project: project)
        // Fetch only the reviewed target object. Do not update local branches or checkout files.
        _ = try await git(["fetch", "--no-tags", "--no-recurse-submodules", "origin", baseSHA], at: workspace.root)
        let mergeBase = try await git(["merge-base", baseSHA, head], at: workspace.root)
        let diff = try await git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", mergeBase, head, "--"], at: workspace.root)
        guard !diff.isEmpty else { throw MochletError.message("There are no committed changes to publish against this target.") }
        let files = try await git(["diff", "--no-ext-diff", "--no-textconv", "--stat", mergeBase, head, "--"], at: workspace.root)
        let commits = try await git(["log", "--format=%h %s", "\(mergeBase)..\(head)"], at: workspace.root)
        guard try await publicationHead(workspace, project: project) == head else { throw MochletError.message("Task changed during review. Prepare again.") }
        return (head, "Target commit: \(baseSHA)\nMerge base: \(mergeBase)\nPublished commit: \(head)\n\nCommits:\n\(commits)\n\nFiles (binary files show only metadata):\n\(files)\n\n\(diff)")
    }
    public static func validatePublication(_ plan: PullRequestPlan, project: Project) async throws {
        guard plan.binding.projectID == project.id, plan.taskID == plan.workspace.taskID,
              try await publicationHead(plan.workspace, project: project) == plan.headSHA else {
            throw MochletError.message("Workspace changed since this preview. Review a new preview before publishing.")
        }
    }
}
