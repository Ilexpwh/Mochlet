import Foundation
import Testing
@testable import SlimeCore

private actor ReplyFixture {
    let service: TeamService
    var writes = 0
    var reply: JSONValue?
    var lost = false
    var changed = false
    var wrongAuthor = false
    var denied = false
    init(_ service: TeamService) { self.service = service }
    func lose() { lost = true }
    func change() { changed = true }
    func impersonate(_ enabled: Bool) { wrongAuthor = enabled }
    func deny(_ enabled: Bool) { denied = enabled }
    func send(_ request: URLRequest) throws -> ConnectorResponse {
        let path = request.url!.path
        let body = try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        let user = wrongAuthor ? "other" : "user"
        var result: JSONValue
        if path.hasSuffix("auth.test") { result = .object(["ok": .bool(true), "team_id": .string("workspace"), "user_id": .string("user")]) }
        else if path.hasSuffix("user_info") { result = .object(["code": .number(0), "data": .object(["tenant_key": .string("workspace"), "open_id": .string("user")])]) }
        else if body["query"].string?.contains("MochletIdentity") == true { result = .object(["data": .object(["viewer": .object(["id": .string("user")]), "organization": .object(["id": .string("workspace")])])]) }
        else if path.hasSuffix("chat.postMessage") {
            if denied { return .init(data: try JSONEncoder().encode(JSONValue.object(["ok": .bool(false), "error": .string("missing_scope")])), status: 200) }
            #expect(body["reply_broadcast"] == .bool(false) && body["mrkdwn"] == .bool(false))
            #expect(body["channel"] == .string("C123") && body["thread_ts"] == .string("1730000000.000001"))
            #expect(body["text"].string?.contains("&lt;@U123&gt;") == true)
            reply = .object(["ts": .string("1730000001.000001"), "thread_ts": body["thread_ts"], "user": .string("user"), "text": body["text"]])
            writes += 1; if lost { throw URLError(.networkConnectionLost) }
            result = .object(["ok": .bool(true), "channel": body["channel"], "ts": reply!["ts"], "message": reply!])
        } else if path.hasSuffix("/reply") {
            #expect(path.contains("/om_root/") && body["reply_in_thread"] == .bool(true))
            #expect(UUID(uuidString: body["uuid"].string ?? "") != nil)
            reply = .object(["message_id": .string("om_reply"), "chat_id": .string("chat"), "root_id": .string("om_root"), "parent_id": .string("om_root"), "thread_id": .string("thread"), "sender": .object(["id": .string("user"), "id_type": .string("open_id")]), "body": .object(["content": body["content"]])])
            writes += 1; if lost { throw URLError(.networkConnectionLost) }
            result = .object(["code": .number(0), "data": reply!])
        } else if body["query"].string?.hasPrefix("mutation ") == true {
            let input = body["variables"]["input"]
            #expect(input["issueId"] == .string("issue") && input["createOnSyncedSlackThread"] == .bool(false))
            reply = .object(["id": input["id"], "body": input["body"], "issue": .object(["id": .string("issue")]), "user": .object(["id": .string("user")])])
            writes += 1; if lost { throw URLError(.networkConnectionLost) }
            result = .object(["data": .object(["commentCreate": .object(["success": .bool(true), "comment": reply!])])])
        } else if path.hasSuffix("conversations.replies") {
            var rows: [JSONValue] = [.object(["ts": .string("1730000000.000001"), "text": .string(changed ? "Changed" : "Source")])]
            if case .object(var row) = reply { row["user"] = .string(user); rows.append(.object(row)) }
            result = .object(["ok": .bool(true), "messages": .array(rows), "has_more": .bool(false)])
        } else if path.hasSuffix("chat.getPermalink") {
            result = .object(["ok": .bool(true), "channel": .string("C123"), "permalink": .string("https://fixture.slack.com/archives/C123/thread")])
        } else if path.hasSuffix("/messages/om_root") || path.hasSuffix("/messages") {
            var rows: [JSONValue] = [.object(["message_id": .string("om_root"), "chat_id": .string("chat"), "thread_id": .string("thread"), "body": .object(["content": .string(changed ? "Changed" : "Source")])])]
            if case .object(var row) = reply { row["sender"] = .object(["id": .string(user), "id_type": .string("open_id")]); rows.append(.object(row)) }
            result = .object(["code": .number(0), "data": .object(["items": .array(rows), "has_more": .bool(false)])])
        } else if path == "/graphql" {
            var rows: [JSONValue] = []
            if case .object(var row) = reply { row["user"] = .object(["id": .string(user)]); rows.append(.object(row)) }
            result = .object(["data": .object(["issue": .object(["id": .string("issue"), "identifier": .string("ENG-1"), "title": .string(changed ? "Changed" : "Source"), "url": .string("https://linear.app/fixture/issue/ENG-1"), "updatedAt": .string("1"), "team": .object(["id": .string("team")]), "comments": .object(["nodes": .array(rows), "pageInfo": .object(["hasNextPage": .bool(false)])])])])])
        } else { throw MochletError.message("Unexpected reply fixture request") }
        return .init(data: try JSONEncoder().encode(result), status: 200)
    }
}
private func replyContext(_ service: TeamService) async throws -> (Store, Project, TeamDelivery, ConnectedSource, ReplyFixture) {
    let store = try Store(path: ":memory:"), project = Project(name: "Reply", root: "/tmp/reply"), fixture = ReplyFixture(service)
    try await store.save(project)
    let reader = TeamReader(service: service, token: "fixture", http: .init { try await fixture.send($0) })
    var account = try await reader.identity(); account.projectIDs = [project.id]; account.scopes.insert(service.rawValue + ".reply.write")
    try await store.saveConnection(account)
    let source = try await reader.read(account: account, collection: service == .slack ? "C123" : "", objectID: service == .slack ? "1730000000.000001" : service == .linear ? "issue" : "om_root")
    return (store, project, TeamDelivery(account: account, reader: reader), source, fixture)
}
@Test(arguments: TeamService.allCases) func reviewedTeamRepliesAreSingleAttemptAndReconcileExactAuthor(_ service: TeamService) async throws {
    let (store, project, delivery, source, fixture) = try await replyContext(service)
    let draft = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123> 廣東話")
    #expect(draft.preview.contains(source.remoteID) && draft.preview.contains("Fixture <@U123> 廣東話"))
    try await store.prepareDelivery(draft); await fixture.lose()
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    let record = try await store.deliveries(accountID: delivery.account.id).first!
    #expect(record.state == "uncertain")
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    await fixture.impersonate(true)
    await #expect(throws: (any Error).self) { try await delivery.reconcile(record, store: store) }
    #expect(try await store.deliveries(accountID: delivery.account.id).first?.state == "uncertain")
    await fixture.impersonate(false); try await delivery.reconcile(record, store: store)
    #expect(try await store.deliveries(accountID: delivery.account.id).first?.state == "delivered")
    #expect(await fixture.writes == 1)
}
@Test(arguments: TeamService.allCases) func teamReplyRejectsStaleSourceAndRevokedPermission(_ service: TeamService) async throws {
    let (store, project, delivery, source, fixture) = try await replyContext(service)
    let draft = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123>")
    try await store.prepareDelivery(draft); await fixture.change()
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    var revoked = delivery.account; revoked.scopes.remove(draft.kind.scope); try await store.saveConnection(revoked)
    await #expect(throws: (any Error).self) { try await store.claimDelivery(draft) }
    #expect(await fixture.writes == 0)
}
@Test(arguments: TeamService.allCases) func teamReplyConfirmsImmediateReceipt(_ service: TeamService) async throws {
    let (store, project, delivery, source, fixture) = try await replyContext(service)
    let draft = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123>")
    try await store.prepareDelivery(draft); try await delivery.execute(draft, store: store)
    #expect(try await store.deliveries(accountID: delivery.account.id).first?.state == "delivered")
    #expect(await fixture.writes == 1)
}
@Test(arguments: TeamService.allCases) func teamReplyReconciliationSurvivesTokenRotationWithReadOnlyAccess(_ service: TeamService) async throws {
    let (store, project, delivery, source, fixture) = try await replyContext(service)
    let draft = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123>")
    try await store.prepareDelivery(draft); await fixture.lose()
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    var renewed = delivery.account; renewed.generation = UUID().uuidString; renewed.scopes.remove(draft.kind.scope)
    try await store.saveConnection(renewed)
    let checker = TeamDelivery(account: renewed, reader: delivery.reader)
    try await checker.reconcile(try await store.deliveries(accountID: renewed.id).first!, store: store)
    #expect(try await store.deliveries(accountID: renewed.id).first?.state == "delivered")
    #expect(await fixture.writes == 1)
}
@Test func slackDefinitiveDenialDoesNotBlockCorrectedReply() async throws {
    let (store, project, delivery, source, fixture) = try await replyContext(.slack)
    let draft = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123>")
    try await store.prepareDelivery(draft); await fixture.deny(true)
    await #expect(throws: (any Error).self) { try await delivery.execute(draft, store: store) }
    #expect(try await store.deliveries(accountID: delivery.account.id).first?.state == "rejected")
    let corrected = try await delivery.prepare(projectID: project.id, source: source, body: "Fixture <@U123>")
    try await store.prepareDelivery(corrected); await fixture.deny(false)
    try await delivery.execute(corrected, store: store)
    #expect(await fixture.writes == 1)
}
