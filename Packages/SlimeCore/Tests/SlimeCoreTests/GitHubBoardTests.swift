import Foundation
import Testing
@testable import SlimeCore

private actor BoardFixture {
    var failValues = false
    var changedOptions = false
    var archived = false
    var partialErrors = false
    var repeatedCursor = false
    var calls: [String] = []
    func configure(fail: Bool = false, options: Bool = false, archived: Bool = false, errors: Bool = false, repeated: Bool = false) {
        failValues = fail; changedOptions = options; self.archived = archived; partialErrors = errors; repeatedCursor = repeated
    }
    func rest(_ path: String) throws -> Data {
        if path == "user" { return Data(#"{"id":1,"login":"person"}"#.utf8) }
        if path == "repos/person/demo" { return Data(#"{"id":20,"full_name":"person/demo","html_url":"https://github.com/person/demo"}"#.utf8) }
        throw MochletError.message("Unexpected REST fixture request")
    }
    func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    func item(_ id: String, kind: String, repo: String = "person/demo") -> [String: Any] {
        var content: [String: Any] = ["id": "CONTENT-" + id, "kind": kind, "title": id]
        if kind != "DraftIssue" { content.merge(["number": 3, "state": "OPEN", "url": "https://github.com/\(repo)/issues/3", "repository": ["id": "R-" + repo, "nameWithOwner": repo]]) { _, new in new } }
        return ["id": id, "isArchived": archived, "updatedAt": "1", "type": kind == "Issue" ? "ISSUE" : kind == "PullRequest" ? "PULL_REQUEST" : "DRAFT_ISSUE", "content": content]
    }
    func page(_ nodes: [[String: Any]], next: String? = nil) -> [String: Any] {
        ["nodes": nodes, "pageInfo": ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]]
    }
    func query(_ query: String, variables: [String: String]) throws -> Data {
        let cursor = variables["cursor"]
        if partialErrors { return try json(["errors": [["message": "Private detail not propagated"]], "data": ["node": NSNull()]]) }
        if query.contains("owner:") { calls.append("metadata"); return try json(["data": ["owner": ["projectV2": ["id": "BOARD", "title": "Fixture", "closed": false, "updatedAt": "1"]]]]) }
        if query.contains("fields(first:") {
            calls.append("fields:" + (cursor ?? "first"))
            let field: [String: Any] = ["id": "STATUS", "name": "Status", "dataType": "SINGLE_SELECT", "options": [["id": "todo", "name": changedOptions ? "Ready" : "Todo"]]]
            let result = cursor == nil ? page([field], next: "fields-2") : page([["id": "TEXT", "name": "Text", "dataType": "TEXT"]])
            return try json(["data": ["node": ["id": "BOARD", "fields": result]]])
        }
        if query.contains("fieldValues(first:") {
            calls.append("values:" + (variables["id"] ?? "") + ":" + (cursor ?? "first"))
            if failValues, cursor != nil { throw MochletError.message("Offline nested page") }
            let value: [String: Any] = cursor == nil ? ["id": "V1", "kind": "ProjectV2ItemFieldSingleSelectValue", "field": ["id": "STATUS"], "name": "Todo", "optionId": "todo"] : ["id": "V2", "kind": "ProjectV2ItemFieldTextValue", "field": ["id": "TEXT"], "text": "A note"]
            let next = cursor == nil || repeatedCursor ? "values-2" : nil
            return try json(["data": ["node": ["id": variables["id"]!, "updatedAt": "1", "fieldValues": page([value], next: next)]]])
        }
        if query.contains("items(first:") {
            calls.append("items:" + (cursor ?? "first"))
            let nodes = cursor == nil ? [item("I1", kind: "Issue")] : [item("P1", kind: "PullRequest"), item("D1", kind: "DraftIssue"), item("OTHER", kind: "Issue", repo: "another/repo")]
            return try json(["data": ["node": ["id": "BOARD", "items": page(nodes, next: cursor == nil ? "items-2" : nil)]]])
        }
        if query.contains("project { id closed }") {
            var result = item("I1", kind: "Issue"); result["project"] = ["id": "BOARD", "closed": false]
            return try json(["data": ["node": result]])
        }
        throw MochletError.message("Unexpected GraphQL fixture query")
    }
}

@Test func githubBoardReadsNestedPagesAndSeparatesCardDestinations() async throws {
    let fixture = BoardFixture(), identity = GitHubClient(request: { try await fixture.rest($0) })
    let client = GitHubBoardClient(identity: identity, request: { try await fixture.query($0, variables: $1) })
    let binding = try await identity.bind(projectID: "project", slug: "person/demo")
    let address = try GitHubBoardAddress(url: "https://github.com/users/person/projects/2/views/1")
    let snapshot = try await client.snapshot(address: address, binding: binding)
    #expect(snapshot.fields.count == 2 && snapshot.items.count == 4)
    #expect(snapshot.items.allSatisfy { $0.values.count == 2 })
    #expect(snapshot.items.filter { $0.canPrepare(binding: binding) }.map(\.id) == ["I1"])
    #expect(await fixture.calls.contains("items:items-2"))
    #expect(await fixture.calls.contains("values:I1:values-2"))
    try await client.verifyItem(snapshot.items[0], snapshot: snapshot)
    await fixture.configure(archived: true)
    await #expect(throws: (any Error).self) { try await client.verifyItem(snapshot.items[0], snapshot: snapshot) }
    await fixture.configure(repeated: true)
    await #expect(throws: (any Error).self) { try await client.snapshot(address: address, binding: binding) }
    await fixture.configure(errors: true)
    await #expect(throws: (any Error).self) { try await client.snapshot(address: address, binding: binding) }
    #expect(throws: (any Error).self) { try GitHubBoardAddress(url: "https://github.com.evil/users/person/projects/1") }
    #expect(throws: (any Error).self) { try GitHubBoardAddress(url: "https://github.com/users/person/projects/-1") }
}

@Test func githubBoardCacheAndStatusMappingRemainExplicitAcrossChanges() async throws {
    let fixture = BoardFixture(), identity = GitHubClient(request: { try await fixture.rest($0) })
    let client = GitHubBoardClient(identity: identity, request: { try await fixture.query($0, variables: $1) })
    let store = try Store(path: ":memory:"), project = Project(name: "Fixture", root: "/tmp/board-fixture")
    try await store.save(project)
    let binding = try await identity.bind(projectID: project.id, slug: "person/demo")
    try await store.bindGitHub(binding)
    let address = try GitHubBoardAddress(url: "https://github.com/users/person/projects/2")
    let snapshot = try await client.snapshot(address: address, binding: binding)
    let first = try await store.saveGitHubBoard(snapshot, expected: nil)
    let mapped = try await store.mapGitHubBoardStatus(fieldID: "STATUS", expected: first)
    #expect(mapped.status(for: snapshot.items[0]) == "Todo")
    await fixture.configure(fail: true)
    await #expect(throws: (any Error).self) {
        let incomplete = try await client.snapshot(address: address, binding: binding)
        _ = try await store.saveGitHubBoard(incomplete, expected: mapped)
    }
    #expect(try await store.githubBoard(binding: binding) == mapped)
    await fixture.configure(options: true)
    let changed = try await client.snapshot(address: address, binding: binding)
    let updated = try await store.saveGitHubBoard(changed, expected: mapped)
    #expect(!updated.statusMappingCurrent)
    #expect(updated.status(for: changed.items[0])?.contains("changed") == true)
    await #expect(throws: (any Error).self) { _ = try await store.mapGitHubBoardStatus(fieldID: "STATUS", expected: mapped) }
    let confirmed = try await store.mapGitHubBoardStatus(fieldID: "STATUS", expected: updated)
    #expect(confirmed.status(for: changed.items[0]) == "Ready")
    let rebound = GitHubBinding(projectID: project.id, account: GitHubAccount(id: 2, login: "other"), repository: binding.repository)
    try await store.bindGitHub(rebound)
    #expect(try await store.githubBoard(binding: binding) == nil)
    #expect(try await store.githubBoard(binding: rebound) == nil)
    await #expect(throws: (any Error).self) { _ = try await store.saveGitHubBoard(changed, expected: confirmed) }
}

@Test func githubBoardTaskSelectionIsDurableAndCannotCrossIssueIdentity() async throws {
    let fixture = BoardFixture(), identity = GitHubClient(request: { try await fixture.rest($0) })
    let client = GitHubBoardClient(identity: identity, request: { try await fixture.query($0, variables: $1) })
    let store = try Store(path: ":memory:"), project = Project(name: "Fixture", root: "/tmp/board-fixture")
    try await store.save(project)
    let binding = try await identity.bind(projectID: project.id, slug: "person/demo")
    try await store.bindGitHub(binding)
    let snapshot = try await client.snapshot(address: GitHubBoardAddress(url: "https://github.com/users/person/projects/2"), binding: binding)
    _ = try await store.saveGitHubBoard(snapshot, expected: nil)
    let selection = GitHubBoardSelection(item: snapshot.items[0], snapshot: snapshot)
    var issue = try JSONDecoder().decode(GitHubIssue.self, from: Data(#"{"id":30,"number":3,"node_id":"CONTENT-I1","title":"I1","state":"open","html_url":"https://github.com/person/demo/issues/3","updated_at":"1"}"#.utf8))
    let task = try await store.prepareGitHubTask(issue, binding: binding, board: selection)
    #expect(try await store.githubTaskBoard(taskID: task.id) == selection)
    issue.node_id = "DIFFERENT_ISSUE"
    await #expect(throws: (any Error).self) { try await store.prepareGitHubTask(issue, binding: binding, board: selection) }
    #expect(try await store.githubTaskBoard(taskID: task.id) == selection)
    issue.node_id = "CONTENT-I1"
    let other = GitHubBoardSelection(item: snapshot.items[3], snapshot: snapshot)
    await #expect(throws: (any Error).self) { try await store.prepareGitHubTask(issue, binding: binding, board: other) }
    _ = try await store.prepareGitHubTask(issue, binding: binding) // Explicit preparation from the issue removes board constraints.
    #expect(try await store.githubTaskBoard(taskID: task.id) == nil)
    let rebound = GitHubBinding(projectID: project.id, account: GitHubAccount(id: 2, login: "other"), repository: binding.repository)
    try await store.bindGitHub(rebound)
    await #expect(throws: (any Error).self) { try await store.prepareGitHubTask(issue, binding: binding) }
}
