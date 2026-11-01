import Foundation
import Testing
@testable import SlimeCore

private actor PublicationFixture {
    let plan: PullRequestPlan
    var head: String?
    var posts = 0
    var receipt: Data?
    var loseResponse = true
    var failHead = false
    var reportedBase: String?
    func failHeadRead() { failHead = true }
    func returnResponse() { loseResponse = false }
    func advanceBase(_ sha: String) { reportedBase = sha }
    init(_ plan: PullRequestPlan) { self.plan = plan }
    func pushed() { head = plan.headSHA }
    func request(_ method: String, _ path: String, _ body: Data?) throws -> Data {
        if path == "user" { return try JSONEncoder().encode(plan.binding.account) }
        if path == "repos/owner/repo" { return try JSONEncoder().encode(plan.binding.repository) }
        if path.contains("/branches/") { return Data("{\"name\":\"main\",\"commit\":{\"sha\":\"\(reportedBase ?? plan.baseSHA)\"}}".utf8) }
        if path.contains("matching-refs") {
            if failHead { failHead = false; throw MochletError.message("Read failed before push") }
            return head.map { Data("[{\"ref\":\"refs/heads/\(plan.workspace.branch)\",\"object\":{\"sha\":\"\($0)\"}}]".utf8) } ?? Data("[]".utf8)
        }
        if method == "GET", path.contains("/pulls?") { return receipt.map { Data("[".utf8) + $0 + Data("]".utf8) } ?? Data("[]".utf8) }
        if method == "POST" {
            posts += 1
            let payload = try JSONSerialization.jsonObject(with: #require(body)) as! [String: Any]
            #expect(payload["draft"] as? Bool == true)
            #expect(payload["head"] as? String == plan.workspace.branch)
            #expect(payload["body"] as? String == plan.remoteBody)
            receipt = try JSONEncoder().encode(PullRequestReceipt(number: 3, html_url: "https://github.com/owner/repo/pull/3", state: "open", draft: true, body: plan.remoteBody,
                head: .init(ref: plan.workspace.branch, sha: plan.headSHA, repo: plan.binding.repository),
                base: .init(ref: "main", sha: plan.baseSHA, repo: plan.binding.repository), merged_at: nil))
            if loseResponse { throw MochletError.message("Response lost after server created PR") }
            return receipt!
        }
        throw MochletError.message("Unexpected fixture request")
    }
}
private func fixtureGit(_ args: [String], root: String) async throws -> String {
    let result = try await CommandProcess().run(executable: "/usr/bin/git", arguments: ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args, cwd: root)
    #expect(result.status == 0)
    return String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
private func publicationContext(_ folder: URL) async throws -> (Store, Project, PullRequestPlan) {
    let root = folder.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await fixtureGit(["init", "-b", "main"], root: root.path)
    try "base".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    _ = try await fixtureGit(["add", "."], root: root.path)
    _ = try await fixtureGit(["commit", "-m", "base"], root: root.path)
    let project = Project(name: "Fixture", root: root.path)
    var task = WorkTask(projectID: project.id, title: "Fix"); task.state = .review
    let workspace = try await TaskWorkspaces.plan(task: task, project: project, folder: folder)
    try await TaskWorkspaces.materialize(workspace, project: project)
    try "fix".write(to: URL(fileURLWithPath: workspace.root).appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    _ = try await fixtureGit(["add", "."], root: workspace.root)
    _ = try await fixtureGit(["commit", "-m", "fix"], root: workspace.root)
    _ = try await fixtureGit(["remote", "add", "origin", root.path], root: root.path)
    let (head, review) = try await TaskWorkspaces.publicationReview(workspace, project: project, baseSHA: workspace.baseCommit)
    #expect(review.contains("+fix"))
    _ = try await fixtureGit(["remote", "set-url", "origin", "https://github.com/owner/repo.git"], root: root.path)
    let binding = GitHubBinding(projectID: project.id, account: GitHubAccount(id: 1, login: "owner"), repository: GitHubRepository(id: 2, full_name: "owner/repo", html_url: "https://github.com/owner/repo"))
    let plan = PullRequestPlan(id: UUID().uuidString, taskID: task.id, binding: binding, workspace: workspace, headSHA: head, baseBranch: "main", baseSHA: workspace.baseCommit, title: "Fix", body: "Fix bug\nValidation: fixture", review: review, createdAt: Date())
    let store = try Store(path: folder.appendingPathComponent("state.sqlite").path)
    try await store.save(project); try await store.save(task); try await store.saveWorkspace(workspace); try await store.bindGitHub(binding)
    try await store.savePublication(plan)
    return (store, project, plan)
}

@Test func publicationLostResponseReconcilesWithoutRepeatingCreate() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, project, plan) = try await publicationContext(folder)
    let fixture = PublicationFixture(plan)
    let api = PullRequestAPI(request: { try await fixture.request($0, $1, $2) })
    let publisher = GitHubPublisher(store: store, api: api, push: { _, _ in await fixture.pushed() })
    let initial = try #require(await store.publications().first)
    await #expect(throws: (any Error).self) { try await publisher.publish(initial, project: project) }
    #expect(await fixture.posts == 1)
    let uncertain = try #require(await store.publications().first)
    #expect(uncertain.state == .creating)
    await #expect(throws: (any Error).self) { try await publisher.publish(uncertain, project: project) }
    await #expect(throws: (any Error).self) { try await store.savePublication(plan) }
    try await publisher.reconcile(uncertain)
    let saved = try #require(await store.publications().first)
    #expect(saved.state == .published && saved.receipt?.number == 3)
    #expect(await fixture.posts == 1)
    let reopened = try Store(path: folder.appendingPathComponent("state.sqlite").path)
    #expect(try await reopened.publications().first?.receipt?.html_url == "https://github.com/owner/repo/pull/3")
}

@Test func publicationRejectsDirtyChangedWorkspaceAndDuplicateClaims() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, project, plan) = try await publicationContext(folder)
    try "uncommitted".write(to: URL(fileURLWithPath: plan.workspace.root).appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await TaskWorkspaces.validatePublication(plan, project: project) }
    _ = try await fixtureGit(["add", "."], root: plan.workspace.root)
    _ = try await fixtureGit(["commit", "-m", "new commit"], root: plan.workspace.root)
    await #expect(throws: (any Error).self) { try await TaskWorkspaces.validatePublication(plan, project: project) }
    try await store.transitionPublication(plan.id, from: .prepared, to: .pushing)
    await #expect(throws: (any Error).self) { try await store.transitionPublication(plan.id, from: .prepared, to: .pushing) }
    for invalid in ["--delete", "main..other", "feature//x", "x.lock", "a/.secret", "main?redirect=1"] {
        #expect(throws: (any Error).self) { try PullRequestAPI.branch(invalid) }
    }
}

@Test func publicationRecoversBranchOnlyWithoutCreatingAutomatically() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, _, plan) = try await publicationContext(folder)
    let fixture = PublicationFixture(plan)
    let api = PullRequestAPI(request: { try await fixture.request($0, $1, $2) })
    let publisher = GitHubPublisher(store: store, api: api)
    try await store.transitionPublication(plan.id, from: .prepared, to: .pushing)
    await fixture.pushed()
    try await publisher.reconcile(#require(await store.publications().first))
    #expect(try await store.publications().first?.state == .ready)
    #expect(await fixture.posts == 0)
    try await store.transitionPublication(plan.id, from: .ready, to: .creating)
    await #expect(throws: (any Error).self) { try await publisher.reconcile(#require(await store.publications().first)) }
    #expect(try await store.publications().first?.state == .creating)
    #expect(await fixture.posts == 0)
}

@Test func publicationReadFailureRemainsRetryableAndAbsentPushReconciles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, project, plan) = try await publicationContext(folder)
    let fixture = PublicationFixture(plan); await fixture.failHeadRead()
    let publisher = GitHubPublisher(store: store, api: PullRequestAPI(request: { try await fixture.request($0, $1, $2) }), push: { _, _ in
        Issue.record("A failed preflight must never invoke push")
    })
    await #expect(throws: (any Error).self) { try await publisher.publish(#require(await store.publications().first), project: project) }
    let reopened = try Store(path: folder.appendingPathComponent("state.sqlite").path)
    #expect(try await reopened.publications().first?.state == .prepared)
    try await reopened.transitionPublication(plan.id, from: .prepared, to: .pushing)
    try await publisher.reconcile(#require(await reopened.publications().first))
    #expect(try await reopened.publications().first?.state == .prepared)
    #expect(await fixture.posts == 0)
}

@Test func pushedPublicationCanBeReviewedAgainAfterTargetAdvances() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (store, project, plan) = try await publicationContext(folder)
    let fixture = PublicationFixture(plan); await fixture.pushed()
    let newBase = String(repeating: "a", count: 40); await fixture.advanceBase(newBase)
    let publisher = GitHubPublisher(store: store, api: PullRequestAPI(request: { try await fixture.request($0, $1, $2) }))
    try await store.transitionPublication(plan.id, from: .prepared, to: .ready)
    await #expect(throws: (any Error).self) { try await publisher.publish(#require(await store.publications().first), project: project) }
    #expect(await fixture.posts == 0)
    try await store.discardPublicationPreview(plan.id)
    // A newly reviewed immutable snapshot keeps the exact pushed head, with a new base and intent marker.
    let fresh = PullRequestPlan(id: UUID().uuidString, taskID: plan.taskID, binding: plan.binding, workspace: plan.workspace,
        headSHA: plan.headSHA, baseBranch: plan.baseBranch, baseSHA: newBase, title: plan.title, body: plan.body, review: "Fresh target review", createdAt: Date())
    try await store.savePublication(fresh)
    let updated = PublicationFixture(fresh); await updated.pushed(); await updated.returnResponse()
    let next = GitHubPublisher(store: store, api: PullRequestAPI(request: { try await updated.request($0, $1, $2) }), push: { _, _ in Issue.record("The reviewed head is already remote; do not push again") })
    try await next.publish(#require(await store.publications().first), project: project)
    #expect(try await store.publications().first?.state == .published)
    #expect(await updated.posts == 1)
}

@Test func publicationPinsSameCredentialForAPIAndIsolatedGit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (_, project, plan) = try await publicationContext(folder)
    let credential = GitHubCredentials(token: "fixture-account-A")
    let api = PullRequestAPI(token: credential.token, http: ConnectorHTTP(transport: { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-account-A")
        let data = request.url?.path == "/user" ? try JSONEncoder().encode(plan.binding.account) : try JSONEncoder().encode(plan.binding.repository)
        return ConnectorResponse(data: data, status: 200)
    }))
    try await api.verify(plan.binding)
    // Project Git may use a different account's SSH key. Publication never invokes this transport.
    _ = try await fixtureGit(["remote", "set-url", "origin", "git@github.com:owner/repo.git"], root: project.root)
    _ = try await fixtureGit(["config", "credential.helper", "account-B-helper"], root: project.root)
    try await credential.push(plan, project: project, execute: { args, cwd, env in
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null" && env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(env["GIT_SSH_COMMAND"] == nil && env["GH_TOKEN"] == nil)
        #expect(!args.contains(where: { $0.contains("fixture-account-A") || $0.contains("account-B") }))
        if args.contains("push") {
            #expect(cwd != plan.workspace.root && cwd != project.root)
            #expect(env["MOCHLET_PUBLICATION_TOKEN"] == "fixture-account-A")
            #expect(args.contains("https://github.com/owner/repo.git"))
            #expect(args.contains("\(plan.headSHA):refs/heads/\(plan.workspace.branch)"))
            #expect(args.contains("--force-with-lease=refs/heads/\(plan.workspace.branch):"))
        }
        return CommandOutput(status: 0, data: Data())
    })
    let isolated = try await CommandProcess().run(executable: "/usr/bin/env", arguments: [], environment: ["ONLY_FIXTURE": "yes"], isolatedEnvironment: true)
    #expect(String(decoding: isolated.data, as: UTF8.self) == "ONLY_FIXTURE=yes\n")
}

@Test func isolatedPublicationPushTransfersObjectsAndCannotOverwriteBranch() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let (_, project, plan) = try await publicationContext(folder)
    let remote = folder.appendingPathComponent("remote.git")
    _ = try await fixtureGit(["init", "--bare", remote.path], root: folder.path)
    let credential = GitHubCredentials(token: "disposable-fixture-token")
    let runner: GitHubCredentials.GitRunner = { args, cwd, environment in
        // The production route stays canonical HTTPS; this test substitutes a disposable local bare repository only.
        let localArgs = args.map { $0 == "https://github.com/owner/repo.git" ? remote.path : $0 }
        return try await CommandProcess().run(executable: "/usr/bin/git", arguments: localArgs, cwd: cwd, environment: environment, isolatedEnvironment: true)
    }
    try await credential.push(plan, project: project, execute: runner)
    #expect(try await fixtureGit(["rev-parse", "refs/heads/" + plan.workspace.branch], root: remote.path) == plan.headSHA)
    _ = try await fixtureGit(["update-ref", "refs/heads/" + plan.workspace.branch, plan.baseSHA], root: remote.path)
    await #expect(throws: (any Error).self) { try await credential.push(plan, project: project, execute: runner) }
    #expect(try await fixtureGit(["rev-parse", "refs/heads/" + plan.workspace.branch], root: remote.path) == plan.baseSHA)
}
