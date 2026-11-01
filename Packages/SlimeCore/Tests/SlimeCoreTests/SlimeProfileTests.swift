import Foundation
import Testing
@testable import SlimeCore

@Test func companionProfilesRetainTaskSnapshotsAcrossEditsArchiveAndReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("state.sqlite").path
    let store = try Store(path: path)
    let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
    let original = try await store.saveProfile(SlimeProfile(name: "Mint", instructions: "Explain in Cantonese", voiceID: "fixture.voice"), expected: nil)
    let task = try await store.createDraft(projectID: project.id, title: "Profile task", provider: .codex, profile: original)
    var edited = original; edited.name = "Peach"; edited.palette = "Peach"; edited.instructions = "Explain in English"; edited.archived = true
    let saved = try await store.saveProfile(edited, expected: original)
    #expect(saved.version == 1)
    await #expect(throws: (any Error).self) { try await store.saveProfile(edited, expected: original) }
    await #expect(throws: (any Error).self) { try await store.createDraft(projectID: project.id, title: "Archived", provider: .codex, profile: saved) }
    let reopened = try Store(path: path)
    #expect(try await reopened.taskProfiles()[task.id] == original)
    #expect(try await reopened.profiles() == [saved])
    var queued = task; queued.state = .queued
    try await reopened.enqueue(queued, prompt: original.contextPrompt(request: "Do this"), readOnly: true, expected: task, profile: original)
    #expect(try await reopened.queuedCommands().first?.1.contains("Explain in Cantonese") == true)
    #expect(try await reopened.taskProfiles()[task.id]?.voiceID == "fixture.voice")
}

@Test func companionProfileAssignmentRejectsRacesAndPreservesSessionIdentity() async throws {
    let store = try Store(path: ":memory:")
    let project = Project(name: "Fixture", root: "/tmp/profile-fixture"); try await store.save(project)
    let first = try await store.saveProfile(SlimeProfile(name: "First"), expected: nil)
    let second = try await store.saveProfile(SlimeProfile(name: "Second"), expected: nil)
    let task = try await store.createDraft(projectID: project.id, title: "Assign", provider: .codex, profile: first)
    try await store.editTask(expected: task, updated: task, details: .init(taskID: task.id), profileChange: .init(expected: first, next: second))
    var queued = task; queued.state = .queued
    await #expect(throws: (any Error).self) { try await store.enqueue(queued, prompt: "Stale profile context", readOnly: true, expected: task, profile: first) }
    #expect(try await store.queuedCommands().isEmpty)
    #expect(try await store.tasks().first?.state == .draft)
    let details = try await store.taskDetails()[task.id]!
    await #expect(throws: (any Error).self) { try await store.editTask(expected: task, updated: task, details: details, profileChange: .init(expected: first, next: nil)) }
    var wrongAgent = task; wrongAgent.provider = AgentProvider.pi.rawValue
    await #expect(throws: (any Error).self) { try await store.editTask(expected: task, updated: wrongAgent, details: details) }
    var established = task; established.threadID = "exact-thread"; established.state = .interrupted
    try await store.save(established)
    var draftAgain = established; draftAgain.state = .draft
    await #expect(throws: (any Error).self) { try await store.editTask(expected: established, updated: draftAgain, details: details, profileChange: .init(expected: second, next: first)) }
    #expect(try await store.taskProfiles()[task.id] == second)
    // Keeping the original snapshot is allowed when reviewing an established session.
    try await store.editTask(expected: established, updated: established, details: details, profileChange: .init(expected: second, next: second))
}

@Test func newTaskProfilesRejectStaleOrMismatchedSelectionsWithoutPartialWrites() async throws {
    let store = try Store(path: ":memory:")
    let project = Project(name: "Fixture", root: "/tmp/profile-fixture"); try await store.save(project)
    let profile = try await store.saveProfile(SlimeProfile(name: "Pi", provider: .pi), expected: nil)
    var edited = profile; edited.instructions = "New instructions"
    let current = try await store.saveProfile(edited, expected: profile)
    var task = WorkTask(projectID: project.id, title: "New task"); task.state = .queued; task.provider = "pi"
    await #expect(throws: (any Error).self) { try await store.enqueue(task, prompt: "Old context", readOnly: false, profile: profile) }
    task.provider = "codex"
    await #expect(throws: (any Error).self) { try await store.enqueue(task, prompt: "Wrong agent", readOnly: true, profile: current) }
    #expect(try await store.tasks().isEmpty)
    #expect(try await store.taskProfiles().isEmpty)
    task.provider = "pi"
    try await store.enqueue(task, prompt: current.contextPrompt(request: "New context"), readOnly: false, profile: current)
    #expect(try await store.taskProfiles()[task.id] == current)
    let legacy = try await store.createDraft(projectID: project.id, title: "Legacy", provider: .pi)
    var queuedLegacy = legacy; queuedLegacy.state = .queued
    await #expect(throws: (any Error).self) { try await store.enqueue(queuedLegacy, prompt: "Implicit profile", readOnly: false, profile: current) }
    try await store.enqueue(queuedLegacy, prompt: "Unprofiled task still works", readOnly: false)
    #expect(try await store.taskProfiles()[legacy.id] == nil)
}
