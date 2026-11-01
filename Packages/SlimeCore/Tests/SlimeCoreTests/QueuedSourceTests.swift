import Foundation
import Testing
@testable import SlimeCore

@Test func queuedSourcePinsCapturedRevisionAcrossCacheRefreshAndRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("store.sqlite").path, store = try Store(path: path)
    let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
    var account = ConnectedAccount(provider: "slack", remoteID: "workspace:user", label: "Fixture", scopes: [TeamService.slack.readCapability]); account.projectIDs = [project.id]
    try await store.saveConnection(account)
    var source = ConnectedSource(accountID: account.id, service: "slack", collection: "C1", remoteID: "1.000001", title: "Source", body: "Original", url: "https://fixture.slack.com/", revision: "1")
    try await store.saveSources([source], account: account)
    let original = try await store.captureSource(source, account: account, projectID: project.id, provider: .codex)
    let ref = try ConnectedMemoryReference(source: source, account: account)
    var queued = original; queued.state = .queued
    try await store.enqueue(queued, prompt: "Original context", readOnly: true, expected: original, sourceEvidence: ref)
    let reopened = try Store(path: path)
    #expect(try await reopened.queuedSource(taskID: original.id) == ref)
    source.body = "New body with unchanged provider revision"
    try await store.saveSources([source], account: account)
    await #expect(throws: (any Error).self) { try await reopened.sourceSnapshot(ref, projectID: project.id) }
    #expect(try await reopened.queuedSource(taskID: original.id) == ref)
    try await store.cancelQueuedCommand(taskID: original.id)
    #expect(try await store.queuedSource(taskID: original.id) == nil)
    var wrong = WorkTask(projectID: project.id, title: "Unbound")
    await #expect(throws: (any Error).self) { try await store.enqueue(wrong, prompt: "context", readOnly: true, sourceEvidence: ref) }
    source.body = "Original"; try await store.saveSources([source], account: account)
    wrong.state = .queued
    await #expect(throws: (any Error).self) { try await store.enqueue(wrong, prompt: "context", readOnly: true, sourceEvidence: ref) }
}
