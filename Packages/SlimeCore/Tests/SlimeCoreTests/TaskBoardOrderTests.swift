import Foundation
import Testing
@testable import SlimeCore

@Test func boardOrderPersistsWithoutChangingTasksOrExecutionQueue() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("board.sqlite").path
    let store = try Store(path: path)
    let project = Project(name: "Board", root: folder.path); try await store.save(project)
    var a = try await store.createDraft(projectID: project.id, title: "A", provider: .codex)
    var b = try await store.createDraft(projectID: project.id, title: "B", provider: .codex)
    a.state = .queued; b.state = .queued
    try await store.enqueue(a, prompt: "a", readOnly: true); try await store.enqueue(b, prompt: "b", readOnly: true)
    let before = try await store.tasks(), order = try await store.taskBoardOrder(projectID: project.id)
    let moved = try await store.moveTaskOnBoard(b.id, relativeTo: a.id, expected: order)
    #expect(moved.taskIDs == [b.id, a.id])
    #expect(try await store.tasks() == before)
    #expect(try await store.queuedCommands().map { $0.0.id } == [a.id, b.id])
    let reopened = try Store(path: path)
    #expect(try await reopened.taskBoardOrder(projectID: project.id) == moved)
    let back = try await store.moveTaskOnBoard(b.id, relativeTo: a.id, after: true, expected: moved)
    #expect(back.taskIDs == [a.id, b.id])
}

@Test func boardOrderRejectsStaleCrossProjectAndCrossColumnMoves() async throws {
    let store = try Store(path: ":memory:")
    let p = Project(name: "A", root: "/tmp/a"), q = Project(name: "B", root: "/tmp/b")
    try await store.save(p); try await store.save(q)
    let a = try await store.createDraft(projectID: p.id, title: "A", provider: .codex)
    let b = try await store.createDraft(projectID: p.id, title: "B", provider: .codex)
    let other = try await store.createDraft(projectID: q.id, title: "Other", provider: .codex)
    let stale = try await store.taskBoardOrder(projectID: p.id)
    let moved = try await store.moveTaskOnBoard(b.id, relativeTo: a.id, expected: stale)
    await #expect(throws: (any Error).self) { try await store.moveTaskOnBoard(a.id, relativeTo: b.id, expected: stale) }
    await #expect(throws: (any Error).self) { try await store.moveTaskOnBoard(other.id, relativeTo: a.id, expected: moved) }
    var review = b; review.state = .review; try await store.save(review)
    await #expect(throws: (any Error).self) { try await store.moveTaskOnBoard(a.id, relativeTo: b.id, expected: moved) }
    let c = try await store.createDraft(projectID: p.id, title: "C", provider: .codex)
    await #expect(throws: (any Error).self) { try await store.moveTaskOnBoard(c.id, relativeTo: a.id, expected: moved) }
    let fresh = try await store.taskBoardOrder(projectID: p.id)
    #expect(fresh.taskIDs == [b.id, a.id, c.id])
    var relocated = c; relocated.projectID = q.id
    try await store.editTask(expected: c, updated: relocated, details: TaskDetails(taskID: c.id))
    #expect(try await store.taskBoardOrder(projectID: p.id).taskIDs == [b.id, a.id])
    #expect(try await store.taskBoardOrder(projectID: q.id).taskIDs == [other.id, c.id])
}
