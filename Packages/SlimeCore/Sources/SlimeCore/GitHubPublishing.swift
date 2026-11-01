import Foundation
import GRDB

public struct PullRequestReceipt: Codable, Sendable, Equatable {
    public struct Ref: Codable, Sendable, Equatable {
        public let ref: String
        public let sha: String
        public let repo: GitHubRepository?
    }
    public let number: Int
    public let html_url: String
    public let state: String
    public let draft: Bool
    public let body: String?
    public let head: Ref
    public let base: Ref
    public let merged_at: String?
}

public struct PullRequestPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let taskID: String
    public let binding: GitHubBinding
    public let workspace: TaskWorkspace
    public let headSHA: String
    public let baseBranch: String
    public let baseSHA: String
    public let title: String
    public let body: String
    public let review: String
    public let createdAt: Date
    public var marker: String { "<!-- mochlet-publication:\(id) -->" }
    public var remoteBody: String { body + "\n\n" + marker }
}

public enum PublicationState: String, Codable, Sendable {
    case prepared, pushing, ready, creating, published
}
public struct Publication: Sendable, Identifiable {
    public var id: String { plan.id }
    public let plan: PullRequestPlan
    public let state: PublicationState
    public let receipt: PullRequestReceipt?
}

extension Store {
    public func publications() throws -> [Publication] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM github_publications ORDER BY rowid DESC").map { row in
                Publication(plan: try JSONDecoder().decode(PullRequestPlan.self, from: row["payload"] as Data),
                    state: PublicationState(rawValue: row["state"])!,
                    receipt: try (row["receipt"] as Data?).map { try JSONDecoder().decode(PullRequestReceipt.self, from: $0) })
            }
        }
    }
    public func savePublication(_ plan: PullRequestPlan) throws {
        try database.write { db in
            guard let task = try WorkTask.fetchOne(db, key: plan.taskID), task.projectID == plan.binding.projectID,
                  ![.queued, .running, .waiting].contains(task.state) else { throw MochletError.message("Finish this task before publishing.") }
            // Only an unsent preview can be replaced. An uncertain attempt cannot be bypassed by making another preview.
            try db.execute(sql: "DELETE FROM github_publications WHERE taskID=? AND state='prepared'", arguments: [plan.taskID])
            try db.execute(sql: "INSERT INTO github_publications(id,taskID,payload,state) VALUES(?,?,?,'prepared')", arguments: [plan.id, plan.taskID, try JSONEncoder().encode(plan)])
        }
    }
    public func transitionPublication(_ id: String, from: PublicationState, to: PublicationState, receipt: PullRequestReceipt? = nil) throws {
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT taskID,payload FROM github_publications WHERE id=? AND state=?", arguments: [id, from.rawValue]) else {
                throw MochletError.message("Publication changed or is already in progress. Reload its state.")
            }
            if from == .prepared || from == .ready {
                guard let task = try WorkTask.fetchOne(db, key: row["taskID"] as String), ![.queued, .running, .waiting].contains(task.state) else {
                    throw MochletError.message("The task resumed. Finish it before publishing.")
                }
                if from == .prepared {
                    let plan = try JSONDecoder().decode(PullRequestPlan.self, from: row["payload"] as Data)
                    guard Date().timeIntervalSince(plan.createdAt) < 900 else { throw MochletError.message("Preview expired. Review a fresh preview.") }
                }
            }
            try db.execute(sql: "UPDATE github_publications SET state=?,receipt=COALESCE(?,receipt) WHERE id=? AND state=?", arguments: [to.rawValue, try receipt.map { try JSONEncoder().encode($0) }, id, from.rawValue])
        }
    }
}

/// The account token is captured once per operation and shared by API requests and the isolated Git transport.
public actor PullRequestAPI {
    public typealias Request = @Sendable (String, String, Data?) async throws -> Data
    private let request: Request
    private let identity: GitHubClient
    init(token: String, http: ConnectorHTTP = ConnectorHTTP()) {
        let send: Request = { method, path, body in
            guard let url = URL(string: "https://api.github.com/" + path), url.host == "api.github.com" else { throw MochletError.message("Invalid GitHub endpoint.") }
            var request = URLRequest(url: url)
            request.httpMethod = method; request.httpBody = body
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return try await http.send(request)
        }
        request = send; identity = GitHubClient(request: { try await send("GET", $0, nil) })
    }
    public init(request: @escaping Request) {
        self.request = request
        identity = GitHubClient(request: { try await request("GET", $0, nil) })
    }
    public func verify(_ binding: GitHubBinding) async throws { try await identity.verify(binding) }
    public static func branch(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_./-]{0,199}$"#, options: .regularExpression) != nil,
              !value.contains(".."), !value.contains("//"), !value.hasSuffix("/"), !value.hasSuffix("."),
              !value.split(separator: "/").contains(where: { $0.hasSuffix(".lock") || $0.hasPrefix(".") }) else { throw MochletError.message("Enter a valid explicit target branch.") }
        return value
    }
    private func path(_ binding: GitHubBinding) throws -> String { "repos/" + (try GitHubClient.validateSlug(binding.repository.full_name)) }
    private func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
    public func baseSHA(_ branch: String, binding: GitHubBinding) async throws -> String {
        struct Branch: Decodable { struct Commit: Decodable { let sha: String }; let name: String; let commit: Commit }
        let value = try Self.branch(branch)
        let result = try JSONDecoder().decode(Branch.self, from: await request("GET", "\(path(binding))/branches/\(component(value))", nil))
        guard result.name == value, Self.validSHA(result.commit.sha) else { throw MochletError.message("Target branch identity is invalid.") }
        return result.commit.sha
    }
    static func validSHA(_ value: String) -> Bool { value.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil }
    public func remoteHead(_ plan: PullRequestPlan) async throws -> String? {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let ref: String; let object: Object }
        let refs = try JSONDecoder().decode([Ref].self, from: await request("GET", "\(path(plan.binding))/git/matching-refs/heads/\(component(plan.workspace.branch))", nil))
        let matches = refs.filter { $0.ref == "refs/heads/" + plan.workspace.branch }
        guard matches.count <= 1, matches.allSatisfy({ Self.validSHA($0.object.sha) }) else { throw MochletError.message("Invalid branch response.") }
        return matches.first?.object.sha
    }
    public func lookup(_ plan: PullRequestPlan) async throws -> PullRequestReceipt? {
        let owner = String(plan.binding.repository.full_name.split(separator: "/")[0])
        let rows = try JSONDecoder().decode([PullRequestReceipt].self, from: await request("GET", "\(path(plan.binding))/pulls?state=all&head=\(component(owner + ":" + plan.workspace.branch))&base=\(component(plan.baseBranch))&per_page=100", nil))
        guard rows.count < 100 else { throw MochletError.message("PR lookup exceeded its bound; no create was attempted.") }
        let own = rows.filter { $0.body?.contains(plan.marker) == true }
        guard own.count <= 1 else { throw MochletError.message("Multiple PRs contain this publication marker. Review them on GitHub.") }
        if let receipt = own.first { try validate(receipt, plan: plan, requireSHA: false); return receipt }
        guard rows.isEmpty else { throw MochletError.message("This branch already has another PR. Open it on GitHub; Mochlet will not create a duplicate.") }
        return nil
    }
    public func create(_ plan: PullRequestPlan) async throws -> PullRequestReceipt {
        let payload: [String: Any] = ["title": plan.title, "body": plan.remoteBody, "head": plan.workspace.branch, "base": plan.baseBranch, "draft": true, "maintainer_can_modify": false]
        let result = try JSONDecoder().decode(PullRequestReceipt.self, from: await request("POST", "\(path(plan.binding))/pulls", JSONSerialization.data(withJSONObject: payload)))
        try validate(result, plan: plan, requireSHA: true)
        guard result.draft else { throw MochletError.message("GitHub returned a non-draft PR. Reconcile and inspect it before continuing.") }
        return result
    }
    private func validate(_ receipt: PullRequestReceipt, plan: PullRequestPlan, requireSHA: Bool) throws {
        let expectedURL = "https://github.com/\(plan.binding.repository.full_name)/pull/\(receipt.number)"
        guard receipt.number > 0, receipt.html_url == expectedURL,
              receipt.head.repo?.id == plan.binding.repository.id, receipt.base.repo?.id == plan.binding.repository.id,
              receipt.head.ref == plan.workspace.branch, receipt.base.ref == plan.baseBranch,
              receipt.body?.contains(plan.marker) == true, !requireSHA || receipt.head.sha == plan.headSHA else {
            throw MochletError.message("PR response does not match the reviewed repository, branches and commit. Reconcile on GitHub.")
        }
    }
}

public actor GitHubPublisher {
    public typealias Push = @Sendable (PullRequestPlan, Project) async throws -> Void
    private let store: Store
    private let api: PullRequestAPI
    private let push: Push
    private var busy = false
    public init(store: Store, api: PullRequestAPI, push: @escaping Push = { _, _ in throw MochletError.message("No authenticated push transport configured.") }) {
        self.store = store; self.api = api; self.push = push
    }
    public func preview(task: WorkTask, project: Project, binding: GitHubBinding, workspace: TaskWorkspace, base: String, title: String, body: String, evidence: String) async throws -> PullRequestPlan {
        guard !busy else { throw MochletError.message("Publication is busy.") }; busy = true; defer { busy = false }
        guard task.id == workspace.taskID, task.projectID == project.id, binding.projectID == project.id,
              ![.running, .waiting, .queued].contains(task.state), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 240, body.utf8.count < 40_000, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              evidence.utf8.count < 10_000 else { throw MochletError.message("Choose a finished task and provide a title, description and test evidence (or explicit untested reason).") }
        guard let issue = try await store.githubTaskIssue(taskID: task.id),
              try await store.githubTaskBinding(taskID: task.id) == binding,
              issue.html_url == "https://github.com/\(binding.repository.full_name)/issues/\(issue.number)" else {
            throw MochletError.message("The task's GitHub issue identity changed. Prepare it again before publishing.")
        }
        try await api.verify(binding)
        try await GitHubClient.verifyRemote(project: project, repository: binding.repository)
        let baseBranch = try PullRequestAPI.branch(base)
        guard baseBranch != workspace.branch else { throw MochletError.message("Base and task branches must differ.") }
        let baseSHA = try await api.baseSHA(baseBranch, binding: binding)
        let (head, review) = try await TaskWorkspaces.publicationReview(workspace, project: project, baseSHA: baseSHA)
        let plan = PullRequestPlan(id: UUID().uuidString, taskID: task.id, binding: binding, workspace: workspace, headSHA: head,
            baseBranch: baseBranch, baseSHA: baseSHA, title: title, body: body + "\n\nSource issue: " + issue.html_url + "\n\nValidation:\n" + evidence,
            review: "Task: \(task.id)\nSource: \(issue.html_url)\n\n" + review, createdAt: Date())
        _ = try await api.lookup(plan)
        try await store.savePublication(plan)
        return plan
    }
    public func publish(_ publication: Publication, project: Project) async throws {
        guard !busy else { throw MochletError.message("Publication is busy.") }; busy = true; defer { busy = false }
        let plan = publication.plan
        guard publication.state == .prepared || publication.state == .ready else { throw MochletError.message("Reconcile this publication; it cannot be sent again.") }
        try await api.verify(plan.binding)
        try await GitHubClient.verifyRemote(project: project, repository: plan.binding.repository)
        try await TaskWorkspaces.validatePublication(plan, project: project)
        guard try await api.baseSHA(plan.baseBranch, binding: plan.binding) == plan.baseSHA else { throw MochletError.message("The target branch advanced. Review its changes before publishing.") }
        if let receipt = try await api.lookup(plan) {
            try await store.transitionPublication(plan.id, from: publication.state, to: .published, receipt: receipt); return
        }
        var state = publication.state
        if state == .prepared {
            let remote = try await api.remoteHead(plan)
            guard remote == nil || remote == plan.headSHA else { throw MochletError.message("Remote task branch differs from the reviewed commit. It will not be overwritten.") }
            try Task.checkCancellation()
            if remote == plan.headSHA {
                try await store.transitionPublication(plan.id, from: .prepared, to: .ready)
            } else {
                try await store.transitionPublication(plan.id, from: .prepared, to: .pushing)
                try await push(plan, project)
                guard try await api.remoteHead(plan) == plan.headSHA else { throw MochletError.message("Branch push outcome is uncertain. Reconcile it.") }
                try await store.transitionPublication(plan.id, from: .pushing, to: .ready)
            }
            state = .ready
        }
        guard try await api.remoteHead(plan) == plan.headSHA else { throw MochletError.message("Remote task branch changed. Inspect it before continuing.") }
        try await api.verify(plan.binding)
        try Task.checkCancellation()
        // Persist before POST: a lost response or app death can never cause an automatic duplicate create.
        try await store.transitionPublication(plan.id, from: state, to: .creating)
        let receipt = try await api.create(plan)
        try await store.transitionPublication(plan.id, from: .creating, to: .published, receipt: receipt)
    }
    public func reconcile(_ publication: Publication) async throws {
        guard !busy else { throw MochletError.message("Publication is busy.") }; busy = true; defer { busy = false }
        try await api.verify(publication.plan.binding)
        if let receipt = try await api.lookup(publication.plan) {
            try await store.transitionPublication(publication.id, from: publication.state, to: .published, receipt: receipt)
        } else if publication.state == .pushing {
            let remote = try await api.remoteHead(publication.plan)
            guard remote == nil || remote == publication.plan.headSHA else { throw MochletError.message("Remote branch differs from the reviewed commit. Inspect it on GitHub.") }
            // No POST was possible in pushing. Repeating a create-only lease push of the same SHA is idempotent.
            try await store.transitionPublication(publication.id, from: .pushing, to: remote == nil ? .prepared : .ready)
        } else {
            throw MochletError.message("No matching PR is visible yet. The previous outcome remains unresolved; no write was repeated. Inspect GitHub and reconcile again.")
        }
    }
}

extension Store {
    public func discardPublicationPreview(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM github_publications WHERE id=? AND state IN ('prepared','ready')", arguments: [id])
            guard db.changesCount == 1 else { throw MochletError.message("Only a preview whose PR creation has not started can be discarded. Any pushed branch remains on GitHub.") }
        }
    }
}
