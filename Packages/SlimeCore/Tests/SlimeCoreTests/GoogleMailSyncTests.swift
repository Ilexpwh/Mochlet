import Foundation
import Testing
@testable import SlimeCore

private struct MailStep: Sendable {
    let suffix: String
    let body: String
    var status = 200
}
private actor MailSyncFixture {
    var steps: [MailStep]
    var queries: [[String: String]] = []
    init(_ steps: [MailStep]) { self.steps = steps }
    func append(_ values: [MailStep]) { steps += values }
    func send(_ request: URLRequest) throws -> ConnectorResponse {
        #expect(request.httpMethod == "GET")
        if request.url!.path == "/v1/userinfo" { return .init(data: Data(#"{"sub":"mail-fixture"}"#.utf8), status: 200) }
        guard !steps.isEmpty else { throw MochletError.message("Unexpected fixture request") }
        let next = steps.removeFirst()
        #expect(request.url!.path.hasSuffix(next.suffix))
        if request.url!.path.hasSuffix("/history") {
            queries.append(Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") }))
        }
        // Failure fixtures represent an outage longer than the interactive retry budget.
        return .init(data: Data(next.body.utf8), status: next.status, retryAfter: next.status == 503 ? "60" : nil)
    }
}
private func mailSyncAccount() -> ConnectedAccount { .init(provider: "google", remoteID: "mail-fixture", label: "Fictional mail", scopes: [GoogleScope.mail]) }
private func trackedSource(_ id: String, account: ConnectedAccount) -> ConnectedSource {
    .init(accountID: account.id, service: "gmail", collection: "threads", remoteID: id, title: "Fictional thread " + id, body: "Fictional message", url: "https://mail.google.com", revision: "90")
}
private func mailThreadStep(_ id: String, revision: String) throws -> MailStep {
    let value: JSONValue = .object(["id": .string(id), "historyId": .string(revision), "messages": .array([
        .object(["id": .string("message-" + id), "payload": .object(["mimeType": .string("text/plain"), "headers": .array([
            .object(["name": .string("Subject"), "value": .string("Fictional planning " + id)])
        ]), "body": .object(["data": .string(Data("Fictional notes for the mint companion.".utf8).base64EncodedString())])])])
    ])])
    return .init(suffix: "/threads/" + id, body: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
}
private func seedTracking(store: Store, account: ConnectedAccount, ids: [String]) async throws {
    try await store.saveConnection(account)
    for id in ids {
        let source = trackedSource(id, account: account)
        try await store.saveSources([source], account: account)
        _ = try await store.trackMail(source, account: account)
    }
}

@Test func mailSyncReadsOnlyTrackedThreadsAndReconcilesMessageDeletion() async throws {
    let store = try Store(path: ":memory:"), account = mailSyncAccount()
    try await seedTracking(store: store, account: account, ids: ["a", "b"])
    let untracked = trackedSource("untracked", account: account)
    try await store.saveSources([untracked], account: account)
    let otherAccount = ConnectedAccount(provider: "google", remoteID: "other-mail-account", label: "Other fixture", scopes: [GoogleScope.mail])
    let otherSource = trackedSource("b", account: otherAccount)
    try await store.saveConnection(otherAccount); try await store.saveSources([otherSource], account: otherAccount)
    let fixture = MailSyncFixture([.init(suffix: "/profile", body: #"{"historyId":"100"}"#), try mailThreadStep("a", revision: "101"), try mailThreadStep("b", revision: "102")])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncTrackedMail(store: store)
    #expect(first.historyID == "100" && first.records.count == 2)
    await fixture.append([
        .init(suffix: "/history", body: #"{"history":[{"id":"120","messagesDeleted":[{"message":{"id":"m1","threadId":"a"}}]},{"id":"121","messagesAdded":[{"message":{"id":"m2","threadId":"new-untracked"}}]}],"nextPageToken":"p2","historyId":"150"}"#),
        .init(suffix: "/history", body: #"{"history":[{"id":"140","labelsAdded":[{"message":{"id":"m3","threadId":"b"},"labelIds":["TRASH"]}]}],"historyId":"160"}"#),
        try mailThreadStep("a", revision: "161"), .init(suffix: "/threads/b", body: "{}", status: 404)
    ])
    let next = try await reader.syncTrackedMail(store: store)
    #expect(next.historyID == "160" && next.threadIDs == ["a"] && next.records.first?.revision == "161")
    let sources = try await store.connectedSources(accountID: account.id)
    #expect(sources.count == 2 && sources.contains(untracked))
    #expect(try await store.connectedSources(accountID: otherAccount.id) == [otherSource])
    let queries = await fixture.queries
    #expect(queries.count == 2 && queries.allSatisfy { $0["startHistoryId"] == "100" } && queries[1]["pageToken"] == "p2")
    await fixture.append([.init(suffix: "/history", body: #"{"historyId":"170"}"#)])
    #expect(try await reader.syncTrackedMail(store: store).records == next.records)
}

@Test func mailSyncKeepsCursorAndRecordsOnPartialHistoryAndThreadFailure() async throws {
    let store = try Store(path: ":memory:"), account = mailSyncAccount()
    try await seedTracking(store: store, account: account, ids: ["a"])
    let fixture = MailSyncFixture([.init(suffix: "/profile", body: #"{"historyId":"100"}"#), try mailThreadStep("a", revision: "101")])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncTrackedMail(store: store)
    let scenarios: [[MailStep]] = [
        [.init(suffix: "/history", body: #"{"history":[],"nextPageToken":"p"}"#), .init(suffix: "/history", body: "{}", status: 503)],
        [.init(suffix: "/history", body: #"{"history":[{"id":"110","messagesAdded":[{"message":{"threadId":"a"}}]}],"historyId":"120"}"#), .init(suffix: "/threads/a", body: "{}", status: 503)],
        [.init(suffix: "/history", body: #"{"history":[{"id":"110","messagesAdded":[{"message":{"id":"missing-thread"}}]}],"historyId":"120"}"#)],
        [.init(suffix: "/history", body: #"{"history":[]}"#)],
        [.init(suffix: "/history", body: #"{"nextPageToken":"loop"}"#), .init(suffix: "/history", body: #"{"nextPageToken":"loop"}"#)]
    ]
    for steps in scenarios {
        await fixture.append(steps)
        await #expect(throws: (any Error).self) { try await reader.syncTrackedMail(store: store) }
        #expect(try await store.mailSnapshot(account: account) == first)
    }
}

@Test func mailSyncExpiredHistoryPreservesTrackingButClearsUnavailableSnapshot() async throws {
    let store = try Store(path: ":memory:"), account = mailSyncAccount()
    try await seedTracking(store: store, account: account, ids: ["a"])
    let untracked = trackedSource("other", account: account)
    try await store.saveSources([untracked], account: account)
    let fixture = MailSyncFixture([.init(suffix: "/profile", body: #"{"historyId":"100"}"#), try mailThreadStep("a", revision: "101")])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    _ = try await reader.syncTrackedMail(store: store)
    await fixture.append([.init(suffix: "/history", body: "{}", status: 404), .init(suffix: "/profile", body: "{}", status: 503)])
    await #expect(throws: (any Error).self) { try await reader.syncTrackedMail(store: store) }
    let cleared = try #require(await store.mailSnapshot(account: account))
    #expect(cleared.historyID == nil && cleared.records.isEmpty && cleared.threadIDs == ["a"])
    #expect(try await store.connectedSources(accountID: account.id) == [untracked])
    await fixture.append([.init(suffix: "/profile", body: #"{"historyId":"200"}"#), try mailThreadStep("a", revision: "201")])
    #expect(try await reader.syncTrackedMail(store: store).records.count == 1)
    await fixture.append([.init(suffix: "/history", body: "{}", status: 404), .init(suffix: "/profile", body: #"{"historyId":"300"}"#), try mailThreadStep("a", revision: "301")])
    #expect(try await reader.syncTrackedMail(store: store).historyID == "300")
}

@Test func mailSyncRejectsChangedTrackingPermissionsAndCancelledCommits() async throws {
    let store = try Store(path: ":memory:")
    var account = mailSyncAccount()
    try await seedTracking(store: store, account: account, ids: ["a"])
    let first = try #require(await store.mailSnapshot(account: account))
    let delta = GoogleMailDelta(historyID: "100", changed: [trackedSource("a", account: account)], deleted: [], startedAt: Date())
    _ = try await store.untrackMail(threadID: "a", account: account)
    await #expect(throws: (any Error).self) { try await store.commitMailSync(delta, account: account, expected: first, replacing: true) }
    let cached = try #require(await store.connectedSources(accountID: account.id).first)
    _ = try await store.trackMail(cached, account: account)
    let current = try #require(await store.mailSnapshot(account: account)), oldAccount = account
    account.generation = UUID().uuidString; try await store.saveConnection(account)
    await #expect(throws: (any Error).self) { try await store.commitMailSync(delta, account: oldAccount, expected: current, replacing: true) }
    await #expect(throws: (any Error).self) { try await store.commitMailSync(delta, account: account, expected: current, replacing: false) }
    let captured = account
    let cancelled = Task { () throws -> GoogleMailSnapshot in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.commitMailSync(delta, account: captured, expected: current, replacing: true)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await store.disconnect(account.id); try await store.saveConnection(account)
    #expect(try await store.mailSnapshot(account: account) == nil)
}

@Test func mailSyncPersistsTrackedContentAndMembershipAcrossRelaunch() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-mail-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let path = temporary.appendingPathComponent("mochlet.sqlite").path
    let store = try Store(path: path), account = mailSyncAccount()
    try await seedTracking(store: store, account: account, ids: ["a"])
    let fixture = MailSyncFixture([.init(suffix: "/profile", body: #"{"historyId":"100"}"#), try mailThreadStep("a", revision: "101")])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncTrackedMail(store: store)
    #expect(try await Store(path: path).mailSnapshot(account: account) == first)
    if let folder = ProcessInfo.processInfo.environment["MOCHLET_MAIL_UI_FIXTURE"], folder.hasPrefix("/"), !FileManager.default.fileExists(atPath: folder) {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let uiStore = try Store(path: URL(fileURLWithPath: folder).appendingPathComponent("mochlet.sqlite").path)
        try await seedTracking(store: uiStore, account: account, ids: ["a"])
        let uiFixture = MailSyncFixture([.init(suffix: "/profile", body: #"{"historyId":"100"}"#), try mailThreadStep("a", revision: "101")])
        _ = try await GoogleReader(account: account, token: "fixture", http: .init { try await uiFixture.send($0) }).syncTrackedMail(store: uiStore)
    }
    let removed = try await store.untrackMail(threadID: "a", account: account)
    #expect(removed.threadIDs.isEmpty && removed.records.isEmpty && removed.historyID == nil)
    #expect(try await store.connectedSources(accountID: account.id).count == 1)
}
