import Foundation
import Testing
@testable import SlimeCore

@Test func recoveredQueuePreservesPromptAndDoesNotReplayStartedRuns() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try Store(path: folder.appendingPathComponent("state.sqlite").path)
    let project = Project(name: "Fixture", root: folder.path)
    try await store.save(project)
    let first = WorkTask(projectID: project.id, title: "First")
    let second = WorkTask(projectID: project.id, title: "Second")
    try await store.enqueue(first, prompt: "first prompt with context", readOnly: true)
    try await store.enqueue(second, prompt: "second prompt", readOnly: false)
    await #expect(throws: (any Error).self) { try await store.enqueue(first, prompt: "duplicate", readOnly: false) }
    try await store.recover()
    let queue = try await store.queuedCommands()
    #expect(queue.map { $0.0.id } == [first.id, second.id])
    #expect(queue[0].1 == "first prompt with context" && queue[0].2)
    var started = first; started.state = .running
    try await store.begin(started, run: Run(taskID: started.id, prompt: queue[0].1))
    try await store.recover()
    #expect(try await store.queuedCommands().map { $0.0.id } == [second.id])
    #expect(try await store.tasks().first { $0.id == first.id }?.state == .interrupted)
    try await store.cancelQueuedCommands()
    #expect(try await store.queuedCommands().isEmpty)
    #expect(try await store.tasks().first { $0.id == second.id }?.state == .cancelled)
}
