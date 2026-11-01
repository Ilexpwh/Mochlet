import Foundation
import Testing
@testable import SlimeCore

private actor DeliveryFixture {
    var writes: [URLRequest] = []
    var lostResponse = false
    var changedThread = false
    var changedEvent = false
    var busy = false
    var messageID = ""
    var event: JSONValue = .object(["id": .string("instance"), "etag": .string("etag-1"), "recurringEventId": .string("series"), "summary": .string("Existing"), "status": .string("confirmed")])
    func loseResponse() { lostResponse = true }
    func changeThread() { changedThread = true }
    func changeEvent() { changedEvent = true }
    func setBusy() { busy = true }
    func send(_ request: URLRequest) throws -> ConnectorResponse {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        var result: JSONValue
        if path == "/v1/userinfo" { result = .object(["sub": .string("fixture")]) }
        else if path.hasSuffix("/threads/thread") {
            result = .object(["id": .string("thread"), "historyId": .string(changedThread ? "2" : "1"), "messages": .array([.object(["payload": .object(["headers": .array([
                .object(["name": .string("Message-ID"), "value": .string("<original@example.invalid>")]),
                .object(["name": .string("Subject"), "value": .string("廣東話 reply")])])])])])])
        } else if path.hasSuffix("/messages/send") || path.hasSuffix("/drafts") {
            #expect(method == "POST"); writes.append(request)
            let payload = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            let encoded = (payload["raw"].string ?? payload["message"]["raw"].string!)
            let base = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let mime = String(decoding: Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))!, as: UTF8.self)
            messageID = mime.components(separatedBy: "\r\n").first { $0.hasPrefix("Message-ID: ") }!.replacingOccurrences(of: "Message-ID: ", with: "")
            #expect(mime.contains("Bcc: hidden@example.invalid") && mime.contains("In-Reply-To: <original@example.invalid>"))
            if lostResponse { throw URLError(.networkConnectionLost) }
            result = .object(["id": .string("sent"), "threadId": .string("thread")])
        } else if path.hasSuffix("/messages") {
            result = .object(["messages": .array([.object(["id": .string("sent")])])])
        } else if path.hasSuffix("/messages/sent") {
            result = .object(["id": .string("sent"), "threadId": .string("thread"), "labelIds": .array([.string("SENT")]), "payload": .object(["headers": .array([.object(["name": .string("Message-ID"), "value": .string(messageID)])])])])
        } else if path.hasSuffix("/freeBusy") {
            #expect(method == "POST")
            result = .object(["calendars": .object(["calendar": .object(["busy": .array(busy ? [.object(["start": .string("2026-11-01T12:00:00Z"), "end": .string("2026-11-01T13:00:00Z")])] : [])])])])
        } else if path.contains("/events"), method != "GET" {
            writes.append(request)
            if method == "PATCH" || method == "DELETE" { #expect(request.value(forHTTPHeaderField: "If-Match") == "etag-1") }
            if let body = request.httpBody { event = try JSONDecoder().decode(JSONValue.self, from: body) }
            if method == "DELETE" { event = .object(["id": .string("instance"), "status": .string("cancelled")]) }
            if lostResponse { throw URLError(.networkConnectionLost) }
            result = .object(["id": .string(event["id"].string ?? "instance"), "etag": .string("etag-2")])
        } else if path.contains("/events/") {
            if changedEvent { result = .object(["id": .string("instance"), "etag": .string("changed"), "status": .string("confirmed")]) }
            else { result = event }
        } else { throw MochletError.message("Unexpected delivery fixture endpoint: " + path) }
        return .init(data: try JSONEncoder().encode(result), status: 200)
    }
}
private func deliveryContext() async throws -> (Store, ConnectedAccount, Project) {
    let store = try Store(path: ":memory:"); let project = Project(name: "Delivery", root: "/tmp/delivery")
    try await store.save(project)
    var account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "sender@example.invalid", scopes: [GoogleScope.mail, GoogleScope.send, GoogleScope.compose, GoogleScope.calendar, GoogleScope.calendarWrite]); account.projectIDs = [project.id]
    try await store.saveConnection(account); return (store, account, project)
}
@Test func mailDeliveryReconcilesLostResponseAndNeverRepeatsTheSend() async throws {
    let (store, account, project) = try await deliveryContext(), fixture = DeliveryFixture()
    let delivery = GoogleDelivery(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let draft = try await delivery.prepareReply(projectID: project.id, threadID: "thread", to: "recipient@example.invalid", cc: "", bcc: "hidden@example.invalid", body: "Fixture body", saveDraft: false)
    #expect(draft.preview.contains("Bcc: hidden@example.invalid") && draft.preview.contains("Attachments: none"))
    try await store.prepareDelivery(draft); await fixture.loseResponse()
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    let uncertain = try await store.deliveries(accountID: account.id).first!
    #expect(uncertain.state == "uncertain" && uncertain.draft == draft)
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    let another = try await delivery.prepareReply(projectID: project.id, threadID: "thread", to: "recipient@example.invalid", cc: "", bcc: "hidden@example.invalid", body: "Fixture body", saveDraft: false)
    await #expect(throws: (any Error).self) { try await store.prepareDelivery(another) }
    try await delivery.reconcile(uncertain, store: store)
    #expect(try await store.deliveries(accountID: account.id).first?.state == "delivered")
    #expect(await fixture.writes.count == 1)
    #expect(throws: (any Error).self) { try GoogleDelivery.addresses("a@example.invalid\r\nBcc: injected@example.invalid") }
}
@Test func deliveryPreviewRejectsChangedRecipientsPermissionsAndThread() async throws {
    let (store, account, project) = try await deliveryContext(), fixture = DeliveryFixture()
    let delivery = GoogleDelivery(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let draft = try await delivery.prepareReply(projectID: project.id, threadID: "thread", to: "a@example.invalid", cc: "", bcc: "hidden@example.invalid", body: "Original", saveDraft: false)
    try await store.prepareDelivery(draft)
    let changed = DeliveryDraft(id: draft.id, account: account, projectID: project.id, kind: draft.kind, collection: draft.collection, remoteID: draft.remoteID, payload: .object(["raw": .string("changed")]), preview: "Different recipients")
    await #expect(throws: (any Error).self) { try await store.claimDelivery(changed) }
    await fixture.changeThread()
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    #expect(await fixture.writes.isEmpty)
    var revoked = account; revoked.scopes.remove(GoogleScope.send); try await store.saveConnection(revoked)
    await #expect(throws: (any Error).self) { try await store.claimDelivery(draft) }
    try await store.disconnect(account.id)
    await #expect(throws: (any Error).self) { try await store.claimDelivery(draft) }
}
@Test func calendarDeliveryUsesStableIDsETagsAndAvailabilityWithoutBlindRetries() async throws {
    let (store, account, project) = try await deliveryContext(), fixture = DeliveryFixture(), now = Date()
    let delivery = GoogleDelivery(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    let created = try await delivery.prepareEvent(projectID: project.id, calendarID: "calendar", source: nil, kind: .calendarCreate, title: "Fixture", start: now, end: now.addingTimeInterval(3600), timeZone: "Asia/Hong_Kong", attendees: "guest@example.invalid", notifications: "all")
    #expect(created.remoteID.range(of: "^[a-v0-9]{32}$", options: .regularExpression) != nil)
    let preparedEarlier = try await delivery.prepareEvent(projectID: project.id, calendarID: "calendar", source: nil, kind: .calendarCreate, title: "Fixture", start: now, end: now.addingTimeInterval(3600), timeZone: "Asia/Hong_Kong", attendees: "guest@example.invalid", notifications: "all")
    try await store.prepareDelivery(preparedEarlier)
    try await store.prepareDelivery(created); await fixture.loseResponse()
    await #expect(throws: (any Error).self) { try await delivery.execute(created, store: store) }
    let duplicate = try await delivery.prepareEvent(projectID: project.id, calendarID: "calendar", source: nil, kind: .calendarCreate, title: "Fixture", start: now, end: now.addingTimeInterval(3600), timeZone: "Asia/Hong_Kong", attendees: "guest@example.invalid", notifications: "all")
    await #expect(throws: (any Error).self) { try await store.prepareDelivery(duplicate) }
    await #expect(throws: (any Error).self) { try await delivery.execute(preparedEarlier, store: store) }
    let record = try await store.deliveries(accountID: account.id).first!
    try await delivery.reconcile(record, store: store)
    #expect(try await store.deliveries(accountID: account.id).first?.state == "delivered")
    #expect(await fixture.writes.count == 1)
    let busyFixture = DeliveryFixture(); await busyFixture.setBusy()
    let busy = GoogleDelivery(account: account, token: "fixture", http: .init { try await busyFixture.send($0) })
    let blocked = try await busy.prepareEvent(projectID: project.id, calendarID: "calendar", source: nil, kind: .calendarCreate, title: "Busy", start: now, end: now.addingTimeInterval(3600), timeZone: "UTC", attendees: "", notifications: "none")
    try await store.prepareDelivery(blocked)
    await #expect(throws: (any Error).self) { try await busy.execute(blocked, store: store) }
    #expect(await busyFixture.writes.isEmpty)
    let updateFixture = DeliveryFixture()
    let update = GoogleDelivery(account: account, token: "fixture", http: .init { try await updateFixture.send($0) })
    let source = ConnectedSource(accountID: account.id, service: "calendar", collection: "calendar", remoteID: "instance", title: "Existing", body: "", url: "", revision: "etag-1")
    let patch = try await update.prepareEvent(projectID: project.id, calendarID: "calendar", source: source, kind: .calendarUpdate, title: "Updated", start: now, end: now.addingTimeInterval(3600), timeZone: "UTC", attendees: "", notifications: "none")
    #expect(patch.preview.contains("Only this occurrence"))
    try await store.prepareDelivery(patch); await updateFixture.changeEvent()
    await #expect(throws: (any Error).self) { try await update.execute(patch, store: store) }
    #expect(await updateFixture.writes.isEmpty)
}

@Test func cancelledClaimBeforeTransportIsNotAnUncertainWrite() async throws {
    let (store, account, project) = try await deliveryContext()
    let draft = DeliveryDraft(account: account, projectID: project.id, kind: .gmailSend, collection: "threads", remoteID: "thread", payload: .null, preview: "Fixture")
    try await store.prepareDelivery(draft); try await store.claimDelivery(draft)
    let delivery = GoogleDelivery(account: account, token: "fixture", http: .init { _ in Issue.record("Cancelled action invoked transport"); return .init(data: Data(), status: 200) })
    let job = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await delivery.transmitClaimed(draft, request: URLRequest(url: URL(string: "https://example.invalid")!), store: store)
    }
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(try await store.deliveries(accountID: account.id).first?.state == "rejected")
    try await store.prepareDelivery(DeliveryDraft(account: account, projectID: project.id, kind: .gmailSend, collection: "threads", remoteID: "thread", payload: .null, preview: "New fixture"))
}
