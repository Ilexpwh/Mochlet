import Foundation
import Testing
@testable import SlimeCore

private actor CalendarSyncFixture {
    var responses: [ConnectorResponse]
    var queries: [[String: String]] = []
    init(_ pages: [ConnectorResponse]) { responses = pages }
    func append(_ pages: [ConnectorResponse]) { responses += pages }
    func send(_ request: URLRequest) throws -> ConnectorResponse {
        if request.url!.path == "/v1/userinfo" { return .init(data: Data(#"{"sub":"calendar-fixture"}"#.utf8), status: 200) }
        #expect(request.httpMethod == "GET")
        #expect(request.url!.path == "/calendar/v3/calendars/calendar/events")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(query["singleEvents"] == "false" && query["showDeleted"] == "true")
        #expect(query["timeMin"] == nil && query["timeMax"] == nil && query["orderBy"] == nil)
        queries.append(query)
        guard !responses.isEmpty else { throw MochletError.message("Unexpected fixture request") }
        return responses.removeFirst()
    }
}
// Failure fixtures represent an outage longer than the interactive retry budget.
private func calendarPage(_ json: String, status: Int = 200) -> ConnectorResponse {
    .init(data: Data(json.utf8), status: status, retryAfter: status == 503 ? "60" : nil)
}

@Test func calendarSyncRetriesOnePageWithoutAdvancingTheSavedCursor() async throws {
    let store = try Store(path: ":memory:"), account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([calendarPage(#"{"items":[{"id":"a","etag":"1"}],"nextSyncToken":"s1"}"#)])
    var reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    reader.readRetry.sleep = { _ in
        let saved = try await store.calendarSnapshot(account: account, calendarID: "calendar")
        #expect(saved?.syncToken == "s1")
        #expect(saved?.records.map(\.remoteID) == ["a"])
    }
    _ = try await reader.syncCalendar(calendarID: "calendar", store: store)
    await fixture.append([
        calendarPage(#"{"items":[{"id":"a","status":"cancelled"}],"nextPageToken":"p2"}"#),
        .init(data: Data("{}".utf8), status: 503),
        calendarPage(#"{"items":[{"id":"b","etag":"2"}],"nextSyncToken":"s2"}"#)
    ])
    let refreshed = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(refreshed.syncToken == "s2" && refreshed.records.map(\.remoteID) == ["b"])
    let queries = await fixture.queries
    #expect(queries.count == 4 && queries[2] == queries[3])
    #expect(queries[2]["syncToken"] == "s1" && queries[2]["pageToken"] == "p2")
}
private func calendarAccount() -> ConnectedAccount { .init(provider: "google", remoteID: "calendar-fixture", label: "Fictional calendar", scopes: [GoogleScope.calendar]) }

@Test func calendarSyncCommitsPagesAndDeletesOnlyBoundCalendarSources() async throws {
    let store = try Store(path: ":memory:"), account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([
        calendarPage(#"{"items":[{"id":"a","etag":"a1","summary":"Alpha"}],"nextPageToken":"p2"}"#),
        calendarPage(#"{"items":[{"id":"b","etag":"b1","summary":"Beta","recurrence":["RRULE:FREQ=DAILY"]}],"nextSyncToken":"s1"}"#)
    ])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(first.records.map(\.remoteID) == ["a", "b"])
    #expect(first.records[1].warnings.contains { $0.contains("series") })
    #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == first)
    let other = ConnectedSource(accountID: account.id, service: "calendar", collection: "another", remoteID: "a", title: "Other calendar", body: "{}", url: "", revision: "a1")
    let instance = ConnectedSource(accountID: account.id, service: "calendar", collection: "calendar", remoteID: "b_instance", title: "Occurrence", body: #"{"recurringEventId":"b"}"#, url: "", revision: "i1")
    try await store.saveSources([other, instance], account: account)
    await fixture.append([
        calendarPage(#"{"items":[{"id":"a","status":"cancelled"}],"nextPageToken":"p3"}"#),
        calendarPage(#"{"items":[{"id":"b","etag":"b2","summary":"Updated"}],"nextSyncToken":"s2"}"#)
    ])
    let second = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(second.records.map(\.revision) == ["b2"] && second.syncToken == "s2")
    let cached = try await store.connectedSources(accountID: account.id)
    #expect(cached.count == 2 && cached.contains(other) && !cached.contains { $0.remoteID == "b_instance" })
    let queries = await fixture.queries
    #expect(queries[0]["syncToken"] == nil && queries[1]["pageToken"] == "p2")
    #expect(queries[2]["syncToken"] == "s1" && queries[3]["syncToken"] == "s1" && queries[3]["pageToken"] == "p3")
}

@Test func calendarSyncFailureDoesNotAdvanceCursorOrLeakPartialChanges() async throws {
    let store = try Store(path: ":memory:"), account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([calendarPage(#"{"items":[{"id":"a","etag":"1"}],"nextSyncToken":"s1"}"#)])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncCalendar(calendarID: "calendar", store: store)
    await fixture.append([calendarPage(#"{"items":[{"id":"a","status":"cancelled"}],"nextPageToken":"p"}"#), calendarPage("{}", status: 503)])
    await #expect(throws: (any Error).self) { try await reader.syncCalendar(calendarID: "calendar", store: store) }
    #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == first)
    #expect(try await store.connectedSources(accountID: account.id).count == 1)
    for bad in [#"{"items":[]}"#, #"{"items":[{"id":"a"}],"nextSyncToken":"bad"}"#,
                #"{"items":[{"id":"a","etag":"1"},{"id":"a","etag":"2"}],"nextSyncToken":"bad"}"#] {
        await fixture.append([calendarPage(bad)])
        await #expect(throws: (any Error).self) { try await reader.syncCalendar(calendarID: "calendar", store: store) }
        #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == first)
    }
    await fixture.append([calendarPage(#"{"items":[],"nextPageToken":"loop"}"#), calendarPage(#"{"items":[],"nextPageToken":"loop"}"#)])
    await #expect(throws: (any Error).self) { try await reader.syncCalendar(calendarID: "calendar", store: store) }
    #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == first)
}

@Test func calendarSyncExpiresAndRebuildsWithoutRetainingStaleRecords() async throws {
    let store = try Store(path: ":memory:"), account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([calendarPage(#"{"items":[{"id":"a","etag":"1"}],"nextSyncToken":"s1"}"#)])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    _ = try await reader.syncCalendar(calendarID: "calendar", store: store)
    await fixture.append([calendarPage("{}", status: 410), calendarPage("{}", status: 503)])
    await #expect(throws: (any Error).self) { try await reader.syncCalendar(calendarID: "calendar", store: store) }
    #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == nil)
    #expect(try await store.connectedSources(accountID: account.id).isEmpty)
    await fixture.append([calendarPage(#"{"items":[{"id":"b","etag":"2"}],"nextSyncToken":"s2"}"#)])
    let rebuilt = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(rebuilt.records.map(\.remoteID) == ["b"])
    await fixture.append([calendarPage("{}", status: 410), calendarPage(#"{"items":[],"nextSyncToken":"s3"}"#)])
    #expect(try await reader.syncCalendar(calendarID: "calendar", store: store).records.isEmpty)
    let queries = await fixture.queries
    #expect(queries[2]["syncToken"] == nil && queries[3]["syncToken"] == nil && queries[5]["syncToken"] == nil)
}

@Test func calendarSyncRejectsStaleConcurrentAndDisconnectedCommits() async throws {
    let store = try Store(path: ":memory:")
    var account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([calendarPage(#"{"items":[],"nextSyncToken":"s1"}"#)])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let delta = try await reader.calendarChanges(calendarID: "calendar", token: nil)
    let first = try await store.commitCalendarSync(delta, account: account, calendarID: "calendar", expected: nil, replacing: true)
    await #expect(throws: (any Error).self) { try await store.commitCalendarSync(delta, account: account, calendarID: "calendar", expected: nil, replacing: true) }
    let oldAccount = account
    account.generation = UUID().uuidString; try await store.saveConnection(account)
    await #expect(throws: (any Error).self) { try await store.commitCalendarSync(delta, account: oldAccount, calendarID: "calendar", expected: first, replacing: false) }
    await #expect(throws: (any Error).self) { try await store.commitCalendarSync(delta, account: account, calendarID: "calendar", expected: first, replacing: false) }
    try await store.disconnect(account.id)
    await #expect(throws: (any Error).self) { try await store.commitCalendarSync(delta, account: account, calendarID: "calendar", expected: first, replacing: true) }
    try await store.saveConnection(account)
    #expect(try await store.calendarSnapshot(account: account, calendarID: "calendar") == nil)
}

@Test func calendarSyncPersistsCancelledOccurrencesUntilRestoredOrSeriesDeleted() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-calendar-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("mochlet.sqlite").path
    let store = try Store(path: path), account = calendarAccount()
    try await store.saveConnection(account)
    let fixture = CalendarSyncFixture([calendarPage(#"{"items":[{"id":"series","etag":"s1","summary":"Fictional weekly planning","recurrence":["RRULE:FREQ=WEEKLY"],"start":{"date":"2026-11-02"},"end":{"date":"2026-11-03"}},{"id":"exception","status":"cancelled","recurringEventId":"series","originalStartTime":{"date":"2026-11-09"}}],"nextSyncToken":"s1"}"#)])
    let reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let first = try await reader.syncCalendar(calendarID: "calendar", store: store)
    let reopened = try Store(path: path)
    #expect(try await reopened.calendarSnapshot(account: account, calendarID: "calendar") == first)
    #expect(try await reopened.savedCalendarIDs(account: account) == ["calendar"])
    #expect(first.cancelledOccurrences.count == 1 && first.records.count == 1)
    // Optional disposable native fixture uses the same verified persistence path, with no OAuth credential.
    if let folder = ProcessInfo.processInfo.environment["MOCHLET_CALENDAR_UI_FIXTURE"], folder.hasPrefix("/"), !FileManager.default.fileExists(atPath: folder) {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let uiStore = try Store(path: URL(fileURLWithPath: folder).appendingPathComponent("mochlet.sqlite").path)
        try await uiStore.saveConnection(account)
        let uiFixture = CalendarSyncFixture([calendarPage(#"{"items":[{"id":"series","etag":"s1","summary":"Fictional weekly planning","recurrence":["RRULE:FREQ=WEEKLY"],"start":{"date":"2026-11-02"},"end":{"date":"2026-11-03"}},{"id":"exception","status":"cancelled","recurringEventId":"series","originalStartTime":{"date":"2026-11-09"}}],"nextSyncToken":"s1"}"#)])
        _ = try await GoogleReader(account: account, token: "fixture", http: .init { try await uiFixture.send($0) }).syncCalendar(calendarID: "calendar", store: uiStore)
    }
    await fixture.append([calendarPage(#"{"items":[],"nextSyncToken":"s2"}"#)])
    #expect(try await reader.syncCalendar(calendarID: "calendar", store: store).cancelledOccurrences.count == 1)
    await fixture.append([calendarPage(#"{"items":[{"id":"exception","etag":"e2","summary":"Restored occurrence","recurringEventId":"series","originalStartTime":{"date":"2026-11-09"}}],"nextSyncToken":"s3"}"#)])
    let restored = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(restored.cancelledOccurrences.isEmpty && restored.records.count == 2)
    await fixture.append([calendarPage(#"{"items":[{"id":"exception","status":"cancelled","recurringEventId":"series","originalStartTime":{"date":"2026-11-09"}},{"id":"another","etag":"e3","summary":"Another occurrence","recurringEventId":"series"}],"nextSyncToken":"s3b"}"#)])
    let cancelledAgain = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(cancelledAgain.cancelledOccurrences.count == 1 && cancelledAgain.records.count == 2)
    await fixture.append([calendarPage(#"{"items":[{"id":"series","status":"cancelled"}],"nextSyncToken":"s4"}"#)])
    let deleted = try await reader.syncCalendar(calendarID: "calendar", store: store)
    #expect(deleted.records.isEmpty && deleted.cancelledOccurrences.isEmpty)
    #expect(try await store.connectedSources(accountID: account.id).isEmpty)
}
