import Foundation
import GRDB

public struct GitHubComment: Codable, Identifiable, Sendable, Equatable {
    public let id: Int64
    public let body: String?
    public let html_url: String
    public let updated_at: String
    public let user: Author?
    public struct Author: Codable, Sendable, Equatable { public let login: String }
}

public struct GitHubDiscussion: Codable, Sendable, Equatable {
    public let binding: GitHubBinding
    public let issue: GitHubIssue
    public let fetchedAt: Date
    public init(binding: GitHubBinding, issue: GitHubIssue, fetchedAt: Date) {
        self.binding = binding; self.issue = issue; self.fetchedAt = fetchedAt
    }
}

extension GitHubIssue {
    public func matchesReviewedSource(_ saved: GitHubIssue) -> Bool {
        id == saved.id && number == saved.number && updated_at == saved.updated_at &&
        body == saved.body && title == saved.title && state == saved.state &&
        (saved.discussion == nil || discussion == saved.discussion)
    }
}

extension GitHubClient {
    /// An explicit selected issue read. Repository sync never fans out across every discussion.
    public func discussion(_ selected: GitHubIssue, binding: GitHubBinding) async throws -> GitHubDiscussion {
        guard selected.number > 0 else { throw MochletError.message("Invalid issue number.") }
        try await verify(binding)
        let endpoint = "repos/\(binding.repository.full_name)/issues/\(selected.number)"
        let before = try await get(endpoint, as: GitHubIssue.self)
        guard before.id == selected.id, before.number == selected.number, before.pull_request == nil else {
            throw MochletError.message("This issue moved or changed identity. Sync the repository again.")
        }
        var comments: [GitHubComment] = []
        var ids = Set<Int64>(), bytes = 0
        for page in 1...6 {
            try Task.checkCancellation()
            let batch = try await get(endpoint + "/comments?per_page=100&page=\(page)", as: [GitHubComment].self)
            guard batch.count <= 100 else { throw MochletError.message("GitHub returned an invalid comment page.") }
            for comment in batch {
                guard comment.id > 0, ids.insert(comment.id).inserted,
                      comments.last.map({ $0.id < comment.id }) ?? true else {
                    throw MochletError.message("Discussion pagination changed. Refresh again; the previous snapshot is preserved.")
                }
                bytes += try JSONEncoder().encode(comment).count
                guard comments.count < 500, bytes <= 2_000_000 else {
                    throw MochletError.message("Discussion exceeds 500 comments or 2 MB. Open it on GitHub; no partial snapshot was saved.")
                }
                comments.append(comment)
            }
            if batch.count < 100 {
                let after = try await get(endpoint, as: GitHubIssue.self)
                guard before == after, after.comments.map({ $0 == comments.count }) ?? true else {
                    throw MochletError.message("The issue changed while loading its discussion. Refresh again.")
                }
                try await verify(binding)
                var snapshot = after; snapshot.discussion = comments
                return GitHubDiscussion(binding: binding, issue: snapshot, fetchedAt: Date())
            }
        }
        throw MochletError.message("Discussion did not finish paging. Previous data was preserved.")
    }
}

extension Store {
    public func githubDiscussion(issueID: Int64, binding: GitHubBinding) throws -> GitHubDiscussion? {
        try database.read { db in
            guard let bindingData = try Data.fetchOne(db, sql: "SELECT payload FROM github_bindings WHERE projectID=?", arguments: [binding.projectID]) else { return nil }
            let current = try JSONDecoder().decode(GitHubBinding.self, from: bindingData)
            guard current.account == binding.account, current.repository == binding.repository else { return nil }
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM github_discussions WHERE projectID=? AND issueID=?", arguments: [binding.projectID, issueID]) else { return nil }
            let saved = try JSONDecoder().decode(GitHubDiscussion.self, from: data)
            guard saved.binding.account == binding.account, saved.binding.repository == binding.repository else { return nil }
            return saved
        }
    }
    public func saveGitHubDiscussion(_ discussion: GitHubDiscussion) throws {
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM github_bindings WHERE projectID=?", arguments: [discussion.binding.projectID]) else { throw MochletError.message("Repository binding was removed.") }
            let current = try JSONDecoder().decode(GitHubBinding.self, from: data)
            guard current.account == discussion.binding.account, current.repository == discussion.binding.repository,
                  discussion.issue.discussion != nil else { throw MochletError.message("Repository binding changed while reading comments.") }
            try db.execute(sql: "INSERT INTO github_discussions(projectID,issueID,payload) VALUES(?,?,?) ON CONFLICT(projectID,issueID) DO UPDATE SET payload=excluded.payload", arguments: [current.projectID, discussion.issue.id, try JSONEncoder().encode(discussion)])
        }
    }
}
