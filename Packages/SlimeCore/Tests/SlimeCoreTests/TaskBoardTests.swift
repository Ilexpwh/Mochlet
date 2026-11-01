import Foundation
import Testing
@testable import SlimeCore

@Test func taskBoardPersistsMetadataCommentsAndRejectsStaleOrRuntimeEdits() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("state.sqlite").path
    let store = try Store(path: path)
    let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
    let task = try await store.createDraft(projectID: project.id, title: "Board", provider: .pi)
    #expect(try await store.queuedCommands().isEmpty)
    var details = TaskDetails(taskID: task.id); details.priority = .urgent; details.description = "Review first"; details.dueAt = 123456
    var edited = task; edited.title = "Reviewed board"
    try await store.editTask(expected: task, updated: edited, details: details)
    try await store.addComment(taskID: task.id, body: "Local comment only")
    let reopened = try Store(path: path)
    #expect(try await reopened.taskDetails()[task.id]?.priority == .urgent)
    #expect(try await reopened.taskDetails()[task.id]?.dueAt == 123456)
    #expect(try await reopened.comments(taskID: task.id).first?.body == "Local comment only")
    await #expect(throws: (any Error).self) { try await store.editTask(expected: task, updated: edited, details: details) }
    await #expect(throws: (any Error).self) { try await store.editTask(expected: edited, updated: edited, details: details) }
    details = try await store.taskDetails()[task.id]!
    var forged = edited; forged.output = "Invented run output"
    await #expect(throws: (any Error).self) { try await store.editTask(expected: edited, updated: forged, details: details) }
    var queued = edited; queued.state = .queued; try await store.enqueue(queued, prompt: "fixture", readOnly: true)
    await #expect(throws: (any Error).self) { try await store.editTask(expected: queued, updated: edited, details: details) }
}

@Test func taskRelationshipsRejectCyclesCrossProjectMovesAndUnfinishedDependencies() async throws {
    let store = try Store(path: ":memory:")
    let project = Project(name: "A", root: "/tmp/a"), other = Project(name: "B", root: "/tmp/b")
    try await store.save(project); try await store.save(other)
    let a = try await store.createDraft(projectID: project.id, title: "A", provider: .codex)
    let b = try await store.createDraft(projectID: project.id, title: "B", provider: .codex)
    let c = try await store.createDraft(projectID: other.id, title: "C", provider: .codex)
    var ad = TaskDetails(taskID: a.id); ad.dependencies = [b.id]
    try await store.editTask(expected: a, updated: a, details: ad)
    var bd = TaskDetails(taskID: b.id); bd.parentID = a.id
    await #expect(throws: (any Error).self) { try await store.editTask(expected: b, updated: b, details: bd) }
    bd.parentID = nil; bd.dependencies = [b.id]
    await #expect(throws: (any Error).self) { try await store.editTask(expected: b, updated: b, details: bd) }
    bd.dependencies = [c.id]
    await #expect(throws: (any Error).self) { try await store.editTask(expected: b, updated: b, details: bd) }
    bd.dependencies = []; var moved = b; moved.projectID = other.id
    await #expect(throws: (any Error).self) { try await store.editTask(expected: b, updated: moved, details: bd) }
    var queued = a; queued.state = .queued
    await #expect(throws: (any Error).self) { try await store.enqueue(queued, prompt: "blocked", readOnly: true) }
    var completed = b; completed.state = .completed
    try await store.editTask(expected: b, updated: completed, details: bd)
    try await store.enqueue(queued, prompt: "ready", readOnly: true)
    bd = try await store.taskDetails()[b.id]!
    try await store.editTask(expected: completed, updated: b, details: bd) // Dependency reopened after queueing.
    var running = queued; running.state = .running
    await #expect(throws: (any Error).self) { try await store.begin(running, run: Run(taskID: a.id, prompt: "must not run")) }
    #expect(try await store.attempts(taskID: a.id).isEmpty)
    try await store.rejectQueuedCommand(taskID: a.id)
    #expect(try await store.queuedCommands().isEmpty)
    #expect(try await store.tasks().first { $0.id == a.id }?.state == .interrupted)
}

@Test func taskDestinationEditsPreserveEstablishedSessionsAndSourceBindings() async throws {
    let store = try Store(path: ":memory:")
    let a = Project(name: "A", root: "/tmp/a"), b = Project(name: "B", root: "/tmp/b")
    try await store.save(a); try await store.save(b)
    let draft = try await store.createDraft(projectID: a.id, title: "Unstarted", provider: .codex)
    var moved = draft; moved.projectID = b.id; moved.provider = AgentProvider.pi.rawValue
    try await store.editTask(expected: draft, updated: moved, details: .init(taskID: draft.id))
    var established = moved; established.state = .interrupted; established.threadID = "exact-session"; established.sessionCWD = b.root; established.sessionConfirmed = true
    try await store.save(established)
    var redirected = established; redirected.projectID = a.id
    await #expect(throws: (any Error).self) { try await store.editTask(expected: established, updated: redirected, details: try await store.taskDetails()[draft.id]!) }
    var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "Fixture", scopes: [GoogleScope.mail]); account.projectIDs = [a.id]
    try await store.saveConnection(account)
    let source = ConnectedSource(accountID: account.id, service: "gmail", collection: "threads", remoteID: "fixture", title: "Mail task", body: "Body", url: "https://mail.google.com/", revision: "1")
    try await store.saveSources([source], account: account)
    let bound = try await store.captureSource(source, account: account, projectID: a.id, provider: .codex)
    var reassign = bound; reassign.provider = AgentProvider.claude.rawValue
    await #expect(throws: (any Error).self) { try await store.editTask(expected: bound, updated: reassign, details: .init(taskID: bound.id)) }
}
