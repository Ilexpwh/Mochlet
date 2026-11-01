import Foundation
import Testing
@testable import SlimeCore

@Test func projectSettingsPersistAndScopeInstructionsWithoutRetargetingHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("test.sqlite").path)
    let a = Project(name: "A", root: root.path), b = Project(name: "B", root: root.appendingPathComponent("b").path)
    try await store.save(a); try await store.save(b)
    var edited = a; edited.name = " App "; edited.aliases = " jelly , 工作 "; edited.instructions = " Use Swift. Project-specific fixture preference. "
    let saved = try await store.editProject(edited, expected: a)
    #expect(saved.name == "App" && saved.aliases == "jelly, 工作")
    let reopened = try Store(path: root.appendingPathComponent("test.sqlite").path)
    let projects = try await reopened.projects()
    #expect(try ProjectResolver.resolve("工作", projects: projects).id == a.id)
    #expect(try ProjectResolver.resolve(" jelly ", projects: projects).id == a.id)
    #expect(try saved.contextPrompt(request: "Current command").contains("Project-specific fixture preference"))
    #expect(try b.contextPrompt(request: "Current command") == "Current command")
    await #expect(throws: (any Error).self) { try await store.editProject(edited, expected: a) }
    var task = WorkTask(projectID: a.id, title: "History"); task.state = .completed; task.threadID = "exact-session"; task.sessionCWD = a.root
    try await store.save(task)
    var moved = saved; moved.root = FileManager.default.temporaryDirectory.path
    await #expect(throws: (any Error).self) { try await store.editProject(moved, expected: saved) }
    #expect(try await store.tasks().first?.threadID == "exact-session")
    #expect(try await store.projects().first(where: { $0.id == a.id })?.root == a.root)
}
@Test func projectEditsAndSubmissionCannotRaceOrRewriteQueuedPreferences() async throws {
    let store = try Store(path: ":memory:"), project = Project(name: "Project", root: "/tmp")
    try await store.save(project)
    var changed = project; changed.instructions = "New preference"
    changed = try await store.editProject(changed, expected: project)
    let task = WorkTask(projectID: project.id, title: "Queued")
    await #expect(throws: (any Error).self) { try await store.enqueue(task, prompt: "stale", readOnly: true, expectedProject: project) }
    #expect(try await store.queuedCommands().isEmpty)
    let prompt = try changed.contextPrompt(request: "Do this")
    try await store.enqueue(task, prompt: prompt, readOnly: true, expectedProject: changed)
    var later = changed; later.instructions = "Later preference"
    await #expect(throws: (any Error).self) { try await store.editProject(later, expected: changed) }
    #expect(try await store.queuedCommands().first?.1 == prompt)
    try await store.cancelQueuedCommand(taskID: task.id)
    _ = try await store.editProject(later, expected: changed)
}
@Test func projectAliasAmbiguityAndInvalidSettingsCannotChooseAnotherRoot() async throws {
    let store = try Store(path: ":memory:")
    let a = Project(name: "A", root: "/tmp", aliases: "shared"), b = Project(name: "B", root: "/var", aliases: "shared")
    try await store.save(a); try await store.save(b)
    #expect(throws: (any Error).self) { try ProjectResolver.resolve("shared", projects: [a, b]) }
    var invalid = a; invalid.root = b.root
    await #expect(throws: (any Error).self) { try await store.editProject(invalid, expected: a) }
    invalid = a; invalid.instructions = String(repeating: "x", count: 16_001)
    await #expect(throws: (any Error).self) { try await store.editProject(invalid, expected: a) }
    invalid = a; invalid.name = " "
    await #expect(throws: (any Error).self) { try await store.editProject(invalid, expected: a) }
}
