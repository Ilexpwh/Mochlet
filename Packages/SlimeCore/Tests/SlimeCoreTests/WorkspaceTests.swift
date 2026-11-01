import Foundation
import Testing
@testable import SlimeCore

@Test func issueWorkspacePreservesDirtyProjectAndRejectsWrongRepository() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = folder.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func git(_ args: [String]) async throws {
        let result = try await CommandProcess().run(executable: "/usr/bin/git", arguments: ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args, cwd: root.path)
        #expect(result.status == 0)
    }
    try await git(["init"])
    try "committed".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try await git(["add", "."]); try await git(["commit", "-m", "Fixture"])
    try "personal edit".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let project = Project(name: "Fixture", root: root.path)
    let task = WorkTask(projectID: project.id, title: "Issue")
    let workspace = try await TaskWorkspaces.plan(task: task, project: project, folder: folder)
    try await TaskWorkspaces.materialize(workspace, project: project)
    try await TaskWorkspaces.materialize(workspace, project: project)
    #expect(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8) == "personal edit")
    let isolatedFile = URL(fileURLWithPath: workspace.root).appendingPathComponent("file.txt")
    #expect(try String(contentsOf: isolatedFile, encoding: .utf8) == "committed")
    try "fixed".write(to: isolatedFile, atomically: true, encoding: .utf8)
    let review = try await TaskWorkspaces.review(workspace, project: project)
    #expect(review.contains("+fixed"))
    #expect(!review.contains("personal edit"))
    let other = Project(name: "Other", root: root.path)
    await #expect(throws: (any Error).self) { try await TaskWorkspaces.validate(workspace, project: other) }
}
