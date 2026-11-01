import Foundation
import Testing
@testable import SlimeCore

private let accountData = Data(#"{"id":10,"login":"person"}"#.utf8)
private let repositoryData = Data(#"{"id":20,"full_name":"person/demo","html_url":"https://github.com/person/demo"}"#.utf8)
private func issueData(_ id: Int, pr: Bool = false) -> Data {
    Data("{\"id\":\(id),\"number\":\(id),\"title\":\"Issue\",\"body\":\"Investigate\",\"state\":\"open\",\"html_url\":\"https://github.com/person/demo/issues/\(id)\",\"updated_at\":\"2026-11-01T00:00:00Z\"\(pr ? ",\"pull_request\":{}" : "")}".utf8)
}
private actor GitHubFixture {
    var changedAccount = false
    var failPages = false
    var pages = 0
    func switchAccount() { changedAccount = true }
    func fail() { failPages = true }
    func request(_ path: String) throws -> Data {
        if path == "user" { return changedAccount ? Data(#"{"id":11,"login":"other"}"#.utf8) : accountData }
        if path == "repos/person/demo" { return repositoryData }
        if path.hasSuffix("&page=1") {
            pages += 1
            return Data("[".utf8) + (1...100).map { issueData($0, pr: $0 == 100) }.reduce(Data()) { result, next in result + (result.isEmpty ? Data() : Data(",".utf8)) + next } + Data("]".utf8)
        }
        if path.hasSuffix("&page=2") {
            if failPages { throw MochletError.message("Offline") }
            return Data("[".utf8) + issueData(101) + Data("]".utf8)
        }
        return issueData(1)
    }
}

@Test func githubSyncChecksIdentityPaginatesAndRejectsPartialSnapshots() async throws {
    let fixture = GitHubFixture()
    let client = GitHubClient(request: { try await fixture.request($0) })
    let binding = try await client.bind(projectID: "project", slug: "person/demo")
    let issues = try await client.issues(binding)
    #expect(issues.count == 100)
    #expect(issues.first?.number == 101)
    #expect(!issues.contains { $0.number == 100 })
    await fixture.fail()
    await #expect(throws: (any Error).self) { try await client.issues(binding) }
    await fixture.switchAccount()
    await #expect(throws: (any Error).self) { try await client.issue(1, binding: binding) }
    #expect(GitHubClient.slug(fromRemote: "git@github.com:person/demo.git\n") == "person/demo")
    #expect(GitHubClient.slug(fromRemote: "https://github.com.evil/person/demo") == nil)
    #expect(throws: (any Error).self) { try GitHubClient.validateSlug("person/demo?x=secret") }
}

@Test func githubTaskPreparationIsDurableAndIdempotent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try Store(path: root.appendingPathComponent("state.sqlite").path)
    let project = Project(name: "Demo", root: root.path)
    try await store.save(project)
    let account = try JSONDecoder().decode(GitHubAccount.self, from: accountData)
    let repo = try JSONDecoder().decode(GitHubRepository.self, from: repositoryData)
    let binding = GitHubBinding(projectID: project.id, account: account, repository: repo)
    let issue = try JSONDecoder().decode(GitHubIssue.self, from: issueData(1))
    try await store.bindGitHub(binding)
    try await store.replaceGitHubIssues([issue], binding: binding)
    await #expect(throws: (any Error).self) { try await store.replaceGitHubIssues([], binding: binding) }
    #expect(try await store.githubIssues(projectID: project.id).count == 1)
    let task = try await store.prepareGitHubTask(issue, binding: binding)
    let repeated = try await store.prepareGitHubTask(issue, binding: binding)
    #expect(task.id == repeated.id)
    #expect(task.state == .draft)
    #expect(try await store.githubTaskBinding(taskID: task.id)?.repository.id == repo.id)
}
