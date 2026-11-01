import Testing
import Foundation
@testable import SlimeCore

@Test func routingRejectsAmbiguityAndWrongSession() throws {
    let a = Project(name: "One", root: "/tmp/a", aliases: "shared")
    let b = Project(name: "Two", root: "/tmp/b", aliases: "shared")
    #expect(throws: MochletError.self) { try ProjectResolver.resolve("shared", projects: [a,b]) }
    #expect(try ProjectResolver.resolve("One", projects: [a,b]).id == a.id)
    #expect(throws: MochletError.self) { try ProjectResolver.verifyCWD(expected: a.root, actual: b.root) }
}

@Test func durableRunRecoveryPreservesSession() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try Store(path: url.path)
    let project = Project(name: "Demo", root: "/tmp")
    try await store.save(project)
    var task = WorkTask(projectID: project.id, title: "Test")
    try await store.enqueue(task, prompt: "Test", readOnly: true)
    task.state = .running; task.threadID = "exact-thread"
    let run = Run(taskID: task.id, prompt: "Test")
    try await store.begin(task, run: run)
    let reopened = try Store(path: url.path)
    try await reopened.recover()
    let tasks = try await reopened.tasks()
    #expect(tasks.count == 1)
    #expect(tasks[0].state == .interrupted)
    #expect(tasks[0].threadID == "exact-thread")
}
