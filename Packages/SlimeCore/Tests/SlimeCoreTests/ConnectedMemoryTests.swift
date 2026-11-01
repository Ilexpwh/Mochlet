import Foundation
import Testing
@testable import SlimeCore

@Test func connectedMemoriesRetainReviewCopiesButDenyDisconnectedAndChangedSources() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try Store(path: ":memory:")
    let project = Project(name: "Fixture", root: "/tmp"); try await store.save(project)
    var account = ConnectedAccount(provider: "google", remoteID: "person", label: "Fixture", scopes: [GoogleScope.drive])
    account.projectIDs = [project.id]; try await store.saveConnection(account)
    let source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: "file", title: "Design", body: "Mint jelly", url: "https://drive.google.com/file/d/file", revision: "1")
    try await store.saveSources([source], account: account)
    var note = KnowledgeNote(scope: project.id, title: source.title, body: source.body)
    try note.bind(source: source, account: account)
    let vault = try KnowledgeVault(directory: folder, allows: { await store.allowsMemory($0) })
    try await vault.save(note)
    let saved = try #require(try await vault.search("mint", scope: project.id).first)
    #expect(saved.connectionJSON == note.connectionJSON)
    #expect(try await vault.isCurrent(saved))
    var moved = saved; moved.scope = "personal"
    #expect(await !store.allowsMemory(moved))
    var noScope = account; noScope.scopes = []
    try await store.saveConnection(noScope)
    #expect(try await vault.search("mint", scope: project.id).isEmpty)
    try await store.saveConnection(account)
    var changed = source; changed.body = "Peach jelly" // Catch content drift even if revision is unchanged.
    try await store.saveSources([changed], account: account)
    #expect(try await vault.search("mint", scope: project.id).isEmpty)
    try await store.saveSources([source], account: account)
    #expect(try await vault.search("mint", scope: project.id).count == 1)
    try await store.disconnect(account.id)
    #expect(try await vault.search("mint", scope: project.id).isEmpty)
    #expect(try await vault.search("mint", scope: project.id, includeUnavailable: true).count == 1)
    #expect(try await !vault.isCurrent(saved))
    // Reconnecting the same remote account creates a new local identity and cannot
    // silently reactivate previously retained evidence.
    var reconnect = ConnectedAccount(provider: "google", remoteID: "person", label: "Fixture", scopes: [GoogleScope.drive])
    reconnect.projectIDs = [project.id]; try await store.saveConnection(reconnect)
    #expect(await !store.allowsMemory(saved))
    let independent = KnowledgeNote(scope: project.id, title: "Explicit local copy", body: saved.body, source: saved.source)
    try await vault.save(independent)
    #expect(try await vault.search("mint", scope: project.id).map(\.id) == [independent.id])
}

@Test func portableConnectedMetadataCannotGrantAccessAndInvalidMetadataFailsClosed() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let vault = try KnowledgeVault(directory: folder)
    var note = KnowledgeNote(scope: "personal", title: "Malformed binding", body: "retain me")
    note.connectionJSON = "not valid JSON"
    try await vault.save(note)
    #expect(try await vault.search("retain", scope: "personal").isEmpty)
    #expect(try await vault.search("retain", scope: "personal", includeUnavailable: true).count == 1)
    let source = await vault.url(note.id)
    let id = try await vault.importDocument(source, scope: "another-project")
    #expect(try await vault.search("retain", scope: "another-project").isEmpty)
    #expect(try await vault.search("retain", scope: "another-project", includeUnavailable: true).first?.id == id)
    let store = try Store(path: ":memory:")
    #expect(await !store.allowsMemory(note))
}

@Test func queuedKnowledgeRechecksRevisionDeletionAndPersistsAcrossRestart() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let vault = try KnowledgeVault(directory: folder)
    let dbPath = folder.appendingPathComponent("tasks.sqlite").path
    let store = try Store(path: dbPath)
    let project = Project(name: "Fixture", root: "/tmp"); try await store.save(project)
    let note = KnowledgeNote(scope: project.id, title: "Fact", body: "Mint")
    try await vault.save(note)
    var saved = try #require(try await vault.search("", scope: project.id).first)
    let evidence = KnowledgeEvidence(saved)
    var task = WorkTask(projectID: project.id, title: "Use memory"); task.state = .queued
    try await store.enqueue(task, prompt: "Fixture", readOnly: true, knowledge: [evidence])
    let reopened = try Store(path: dbPath)
    #expect(try await reopened.queuedKnowledge(taskID: task.id) == [evidence])
    #expect(try await vault.resolve(evidence) == saved)
    saved.body = "Peach"; try await vault.save(saved, expectedRevision: saved.revision)
    await #expect(throws: (any Error).self) { _ = try await vault.resolve(evidence) }
    let changed = try #require(try await vault.search("", scope: project.id).first)
    try await vault.remove(saved.id)
    await #expect(throws: (any Error).self) { _ = try await vault.resolve(KnowledgeEvidence(changed)) }
    try await reopened.cancelQueuedCommand(taskID: task.id)
    #expect(try await reopened.queuedKnowledge(taskID: task.id).isEmpty)
}
