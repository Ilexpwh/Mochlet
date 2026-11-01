import Foundation
import Testing
@testable import SlimeCore

private actor DiscussionFixture {
    var failSecondPage = false
    var switchAccountAtEnd = false
    var edited = false
    var omitLastComment = false
    var accountReads = 0
    var commentReads = 0
    func configure(fail: Bool = false, switchAccount: Bool = false, edited: Bool = false, omit: Bool = false) {
        failSecondPage = fail; switchAccountAtEnd = switchAccount; self.edited = edited; omitLastComment = omit
        accountReads = 0; commentReads = 0
    }
    func issue() throws -> GitHubIssue {
        try JSONDecoder().decode(GitHubIssue.self, from: Data(#"{"id":12,"number":3,"title":"Bug","body":"Reproduce","state":"open","html_url":"https://github.com/person/demo/issues/3","updated_at":"2026-11-01T00:00:00Z","comments":101}"#.utf8))
    }
    func request(_ path: String) throws -> Data {
        if path == "user" {
            accountReads += 1
            return Data("{\"id\":\(switchAccountAtEnd && commentReads > 0 ? 2 : 1),\"login\":\"person\"}".utf8)
        }
        if path == "repos/person/demo" { return Data(#"{"id":20,"full_name":"person/demo","html_url":"https://github.com/person/demo"}"#.utf8) }
        if path == "repos/person/demo/issues/3" { return try JSONEncoder().encode(issue()) }
        if path.contains("/comments?") {
            commentReads += 1
            let first = path.hasSuffix("page=1")
            if !first, failSecondPage { throw MochletError.message("Offline second page") }
            if !first, omitLastComment { return Data("[]".utf8) }
            let ids = first ? Array(1...100) : [101]
            let comments = ids.map { id in
                "{\"id\":\(id),\"body\":\"\(edited && id == 1 ? "Edited reproduction" : "Reproduction")\",\"html_url\":\"https://github.com/person/demo/issues/3#issuecomment-\(id)\",\"updated_at\":\"2026-11-01T00:00:00Z\",\"user\":{\"login\":\"maintainer\"}}"
            }
            return Data(("[" + comments.joined(separator: ",") + "]").utf8)
        }
        throw MochletError.message("Unexpected fixture endpoint")
    }
}

@Test func githubDiscussionPagesAndDetectsCommentEditsBeyondIssueTimestamp() async throws {
    let fixture = DiscussionFixture(), client = GitHubClient(request: { try await fixture.request($0) })
    let binding = try await client.bind(projectID: "fixture", slug: "person/demo")
    let issue = try await fixture.issue()
    let saved = try await client.discussion(issue, binding: binding)
    #expect(saved.issue.discussion?.count == 101)
    #expect(saved.issue.discussion?.last?.id == 101)
    await fixture.configure(edited: true)
    let fresh = try await client.issue(3, binding: binding, includeDiscussion: true)
    #expect(fresh.updated_at == saved.issue.updated_at)
    #expect(!fresh.matchesReviewedSource(saved.issue))
    #expect(fresh.matchesReviewedSource(issue)) // Legacy body-only tasks retain their scope.
    await fixture.configure(omit: true)
    await #expect(throws: (any Error).self) { try await client.discussion(issue, binding: binding) }
    await fixture.configure(switchAccount: true)
    await #expect(throws: (any Error).self) { try await client.discussion(issue, binding: binding) }
}

@Test func githubDiscussionKeepsCompleteCacheOnFailureAndSeparatesAccounts() async throws {
    let fixture = DiscussionFixture(), client = GitHubClient(request: { try await fixture.request($0) })
    let store = try Store(path: ":memory:")
    let project = Project(name: "Discussion", root: "/tmp/discussion"); try await store.save(project)
    let binding = try await client.bind(projectID: project.id, slug: "person/demo")
    try await store.bindGitHub(binding)
    let issue = try await fixture.issue(), saved = try await client.discussion(issue, binding: binding)
    try await store.saveGitHubDiscussion(saved)
    let task = try await store.prepareGitHubTask(saved.issue, binding: binding)
    #expect(try await store.githubTaskIssue(taskID: task.id)?.discussion == saved.issue.discussion)
    await fixture.configure(fail: true)
    await #expect(throws: (any Error).self) {
        let partial = try await client.discussion(issue, binding: binding)
        try await store.saveGitHubDiscussion(partial)
    }
    #expect(try await store.githubDiscussion(issueID: issue.id, binding: binding) == saved)
    let rebound = GitHubBinding(projectID: project.id, account: GitHubAccount(id: 99, login: "other"), repository: binding.repository)
    try await store.bindGitHub(rebound)
    #expect(try await store.githubDiscussion(issueID: issue.id, binding: rebound) == nil)
    #expect(try await store.githubDiscussion(issueID: issue.id, binding: binding) == nil)
    await #expect(throws: (any Error).self) { try await store.saveGitHubDiscussion(saved) }
}
