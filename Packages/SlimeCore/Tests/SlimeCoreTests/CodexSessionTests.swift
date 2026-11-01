import Foundation
import Testing
@testable import SlimeCore

private actor SessionCatalogFixture {
    let id = UUID().uuidString
    let root: String
    var wrongCWD = false
    var wrongID = false
    var duplicate = false
    var repeated = false
    var methods: [String] = []
    init(root: String) { self.root = root }
    func wrongProject() { wrongCWD = true }
    func wrongIdentity() { wrongID = true }
    func duplicatePage() { duplicate = true }
    func repeatCursor() { repeated = true }
    func thread() -> JSONValue {
        .object(["id": .string(wrongID ? UUID().uuidString : id), "cwd": .string(wrongCWD ? root + "/elsewhere" : root),
            "source": .string("cli"), "status": .object(["type": .string("notLoaded")]), "updatedAt": .number(100),
            "ephemeral": .bool(false), "name": .string("Existing session"), "preview": .string("Question")])
    }
    func call(_ method: String, _ params: JSONValue) throws -> JSONValue {
        methods.append(method)
        switch method {
        case "thread/list":
            #expect(params["cwd"].string == root)
            #expect(params["useStateDbOnly"] == .bool(true))
            #expect(params["limit"].number == 25)
            return .object(["data": .array(duplicate ? [thread(), thread()] : [thread()]), "nextCursor": repeated ? params["cursor"] : .string("next")])
        case "thread/read":
            #expect(params["includeTurns"] == .bool(false))
            return .object(["thread": thread()])
        case "thread/turns/list":
            #expect(params["limit"].number == 20)
            return .object(["data": .array([.object(["id": .string("turn"), "status": .string("completed"), "items": .array([
                .object(["type": .string("agentMessage"), "id": .string("message"), "text": .string(String(repeating: "x", count: 25_000))]),
                .object(["type": .string("futureItem"), "id": .string("unknown")])])])]), "nextCursor": .null])
        default: throw MochletError.message("Mutation attempted by read-only catalog")
        }
    }
}

@Test func storedCodexCatalogScopesReadsAndBoundsHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let project = Project(name: "Fixture", root: folder.path)
    let fixture = SessionCatalogFixture(root: project.root)
    let catalog = CodexSessionCatalog(request: { try await fixture.call($0, $1) })
    let page = try await catalog.list(project: project)
    #expect(page.sessions.count == 1 && page.nextCursor == "next")
    let history = try await catalog.history(id: fixture.id, project: project)
    #expect(history.text.contains("Display truncated") && history.text.contains("details not rendered"))
    #expect(history.text.count < 21_000)
    #expect(await fixture.methods.allSatisfy { ["thread/list", "thread/read", "thread/turns/list"].contains($0) })
    await fixture.repeatCursor()
    await #expect(throws: (any Error).self) { try await catalog.list(project: project, after: "next") }
    await fixture.wrongProject()
    await #expect(throws: (any Error).self) { try await catalog.history(id: fixture.id, project: project) }
}

@Test func storedCodexCatalogRejectsWrongIdentityAndDuplicatePages() async throws {
    let project = Project(name: "Fixture", root: FileManager.default.temporaryDirectory.path)
    let fixture = SessionCatalogFixture(root: project.root)
    let catalog = CodexSessionCatalog(request: { try await fixture.call($0, $1) })
    await fixture.duplicatePage()
    await #expect(throws: (any Error).self) { try await catalog.list(project: project) }
    await fixture.wrongIdentity()
    await #expect(throws: (any Error).self) { try await catalog.read(id: fixture.id, project: project) }
}

@Test func importedCodexSessionsKeepExactProjectAndNeverQueueAutomatically() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try Store(path: folder.appendingPathComponent("state.sqlite").path)
    let project = Project(name: "Fixture", root: folder.path); try await store.save(project)
    let fixture = SessionCatalogFixture(root: project.root)
    let catalog = CodexSessionCatalog(request: { try await fixture.call($0, $1) })
    let session = try await catalog.read(id: fixture.id, project: project)
    await #expect(throws: (any Error).self) { try await store.importCodexSession(session, project: project, externalClientStopped: false) }
    let task = try await store.importCodexSession(session, project: project, externalClientStopped: true)
    #expect(task.threadID == session.id && task.sessionCWD == project.root && task.state == .interrupted)
    #expect(task.sessionConfirmed && task.provider == "codex")
    #expect(try await store.importCodexSession(session, project: project, externalClientStopped: true).id == task.id)
    #expect(try await store.queuedCommands().isEmpty)
    var queued = task; queued.state = .queued
    try await store.enqueue(queued, prompt: "Explicit follow-up", readOnly: true)
    await #expect(throws: (any Error).self) { try await store.importCodexSession(session, project: project, externalClientStopped: true) }
    let active = StoredCodexSession(id: UUID().uuidString, cwd: project.root, title: "Busy", preview: "", source: "cli", serverStatus: "active", updatedAt: Date(), observedAt: Date())
    await #expect(throws: (any Error).self) { try await store.importCodexSession(active, project: project, externalClientStopped: true) }
    let stale = StoredCodexSession(id: UUID().uuidString, cwd: project.root, title: "Stale", preview: "", source: "cli", serverStatus: "notLoaded", updatedAt: Date(), observedAt: Date(timeIntervalSinceNow: -120))
    await #expect(throws: (any Error).self) { try await store.importCodexSession(stale, project: project, externalClientStopped: true) }
}
