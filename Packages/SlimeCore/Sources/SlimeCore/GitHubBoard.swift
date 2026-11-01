import Foundation

public struct GitHubBoardAddress: Codable, Sendable, Equatable {
    public let owner: String
    public let organization: Bool
    public let number: Int
    public init(url: String) throws {
        guard let value = URLComponents(string: url), value.scheme == "https", value.host == "github.com",
              value.user == nil, value.password == nil, value.port == nil else { throw MochletError.message("Use a GitHub Projects URL such as https://github.com/users/name/projects/1.") }
        let parts = value.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, ["users", "orgs"].contains(parts[0]), parts[2] == "projects",
              parts[1].range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"#, options: .regularExpression) != nil,
              let number = Int(parts[3]), number > 0, number <= Int(Int32.max),
              parts.count == 4 || (parts.count == 6 && parts[4] == "views" && Int(parts[5]) != nil) else {
            throw MochletError.message("Choose an organization or user Projects board URL.")
        }
        owner = parts[1]; organization = parts[0] == "orgs"; self.number = number
    }
    public var url: String { "https://github.com/\(organization ? "orgs" : "users")/\(owner)/projects/\(number)" }
}

public struct GitHubBoardField: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let dataType: String
    public let options: [Option]?
    public struct Option: Codable, Sendable, Equatable, Identifiable { public let id: String; public let name: String }
}
public struct GitHubBoardValue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let field: Field?
    public let text: String?
    public let date: String?
    public let number: Double?
    public let name: String?
    public let optionId: String?
    public struct Field: Codable, Sendable, Equatable { public let id: String }
    public var display: String { text ?? date ?? name ?? number.map(String.init(describing:)) ?? "Unsupported field value" }
}
public struct GitHubBoardItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let isArchived: Bool
    public let updatedAt: String
    public let type: String
    public let content: Content?
    public var values: [GitHubBoardValue] = []
    private enum CodingKeys: String, CodingKey { case id, isArchived, updatedAt, type, content, values }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); isArchived = try c.decode(Bool.self, forKey: .isArchived)
        updatedAt = try c.decode(String.self, forKey: .updatedAt); type = try c.decode(String.self, forKey: .type)
        content = try c.decodeIfPresent(Content.self, forKey: .content)
        values = try c.decodeIfPresent([GitHubBoardValue].self, forKey: .values) ?? []
    }
    public struct Content: Codable, Sendable, Equatable {
        public let kind: String
        public let id: String
        public let title: String
        public let number: Int?
        public let state: String?
        public let url: String?
        public let repository: Repository?
        private enum CodingKeys: String, CodingKey { case kind, id, title, number, state, url, repository }
        private enum RemoteKeys: String, CodingKey { case issueState, pullRequestState }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let remote = try decoder.container(keyedBy: RemoteKeys.self)
            kind = try c.decode(String.self, forKey: .kind); id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title); number = try c.decodeIfPresent(Int.self, forKey: .number)
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? remote.decodeIfPresent(String.self, forKey: .issueState) ?? remote.decodeIfPresent(String.self, forKey: .pullRequestState)
            url = try c.decodeIfPresent(String.self, forKey: .url); repository = try c.decodeIfPresent(Repository.self, forKey: .repository)
        }
    }
    public struct Repository: Codable, Sendable, Equatable { public let id: String; public let nameWithOwner: String }
    public func canPrepare(binding: GitHubBinding) -> Bool {
        !isArchived && content?.kind == "Issue" && content?.state == "OPEN" &&
        content?.repository?.nameWithOwner.caseInsensitiveCompare(binding.repository.full_name) == .orderedSame
    }
}
public struct GitHubBoardSnapshot: Codable, Sendable, Equatable {
    public let binding: GitHubBinding
    public let address: GitHubBoardAddress
    public let id: String
    public let title: String
    public let closed: Bool
    public let updatedAt: String
    public let fields: [GitHubBoardField]
    public let items: [GitHubBoardItem]
    public let fetchedAt: Date
}
public struct GitHubBoardSelection: Codable, Sendable, Equatable {
    public let boardID: String
    public let boardURL: String
    public let binding: GitHubBinding
    public let item: GitHubBoardItem
    public init(item: GitHubBoardItem, snapshot: GitHubBoardSnapshot) {
        boardID = snapshot.id; boardURL = snapshot.address.url; binding = snapshot.binding; self.item = item
    }
}

/// GraphQL reads only; gh owns credentials. Each nested connection is paged explicitly.
public actor GitHubBoardClient {
    public typealias Request = @Sendable (String, [String: String]) async throws -> Data
    private let request: Request
    private let identity: GitHubClient
    public init(executable: String) {
        identity = GitHubClient(executable: executable)
        request = { query, variables in
            var arguments = ["api", "--hostname", "github.com", "graphql", "-f", "query=" + query]
            for key in variables.keys.sorted() { arguments += ["-f", key + "=" + variables[key]!] }
            let result = try await CommandProcess().run(executable: executable, arguments: arguments)
            guard result.status == 0 else { throw MochletError.message("GitHub Projects request failed. Check the selected account and Projects read permission in gh; no permissions were changed.") }
            return result.data
        }
    }
    public init(identity: GitHubClient, request: @escaping Request) { self.identity = identity; self.request = request }
    private struct Envelope<T: Decodable>: Decodable {
        let data: T?
        let errors: [JSONValue]?
    }
    private struct Node<T: Decodable>: Decodable { let node: T? }
    private struct Owner: Decodable { let projectV2: Metadata? }
    private struct OwnerResult: Decodable { let owner: Owner? }
    private struct Metadata: Codable, Equatable { let id: String; let title: String; let closed: Bool; let updatedAt: String }
    private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
    private struct Page<T: Decodable>: Decodable { let nodes: [T?]; let pageInfo: PageInfo }
    private struct Fields: Decodable { let id: String; let fields: Page<GitHubBoardField> }
    private struct Items: Decodable { let id: String; let items: Page<GitHubBoardItem> }
    private struct Values: Decodable { let id: String; let updatedAt: String; let fieldValues: Page<GitHubBoardValue> }
    private struct ItemCheck: Decodable { let id: String; let isArchived: Bool; let updatedAt: String; let type: String; let content: GitHubBoardItem.Content?; let project: ProjectID }
    private struct ProjectID: Decodable { let id: String; let closed: Bool }
    private final class ReadBudget {
        var requests = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        func take() throws {
            requests += 1
            guard requests <= 200, ProcessInfo.processInfo.systemUptime < deadline else {
                throw MochletError.message("Board refresh exceeded its 200-request or two-minute budget. Previous snapshot was preserved.")
            }
        }
    }
    private func call<T: Decodable>(_ query: String, variables: [String: String], as: T.Type, budget: ReadBudget? = nil) async throws -> T {
        try Task.checkCancellation()
        try budget?.take()
        let bytes = try await request(query, variables)
        guard bytes.count <= 8_000_000 else { throw MochletError.message("Projects response exceeds 8 MB.") }
        let result = try JSONDecoder().decode(Envelope<T>.self, from: bytes)
        guard result.errors?.isEmpty != false, let data = result.data else { throw MochletError.message("GitHub returned incomplete Projects data. Check account/board access and refresh; the last complete snapshot was preserved.") }
        return data
    }
    private static let metadata = "id title closed updatedAt"
    private static let field = "... on ProjectV2Field { id name dataType } ... on ProjectV2IterationField { id name dataType } ... on ProjectV2SingleSelectField { id name dataType options { id name } }"
    private static let content = "content { kind:__typename ... on Issue { id title number issueState:state url repository { id nameWithOwner } } ... on PullRequest { id title number pullRequestState:state url repository { id nameWithOwner } } ... on DraftIssue { id title } }"
    private static let value = "kind:__typename ... on ProjectV2ItemFieldValueCommon { id } ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id } } } ... on ProjectV2ItemFieldDateValue { date field { ... on ProjectV2FieldCommon { id } } } ... on ProjectV2ItemFieldNumberValue { number field { ... on ProjectV2FieldCommon { id } } } ... on ProjectV2ItemFieldSingleSelectValue { name optionId field { ... on ProjectV2FieldCommon { id } } } ... on ProjectV2ItemFieldIterationValue { name:title field { ... on ProjectV2FieldCommon { id } } }"
    private static let pageInfo = "pageInfo { hasNextPage endCursor }"
    private func next<T>(_ page: Page<T>, seen: inout Set<String>) throws -> String? {
        guard page.nodes.count <= 100, !page.nodes.contains(where: { $0 == nil }) else { throw MochletError.message("Projects returned missing or invalid connection entries.") }
        guard page.pageInfo.hasNextPage else { return nil }
        guard let cursor = page.pageInfo.endCursor, !cursor.isEmpty, seen.insert(cursor).inserted else { throw MochletError.message("Projects pagination did not advance.") }
        return cursor
    }
    private func fields(id: String, budget: ReadBudget) async throws -> [GitHubBoardField] {
        var variables = ["id": id], cursors = Set<String>(), result: [GitHubBoardField] = []
        for _ in 0..<5 {
            let data = try await call("query($id:ID!,$cursor:String) { node(id:$id) { ... on ProjectV2 { id fields(first:100,after:$cursor) { nodes { \(Self.field) } \(Self.pageInfo) } } } }", variables: variables, as: Node<Fields>.self, budget: budget)
            guard let node = data.node, node.id == id else { throw MochletError.message("Projects board is unavailable.") }
            let cursor = try next(node.fields, seen: &cursors)
            result += node.fields.nodes.compactMap { $0 }
            guard Set(result.map(\.id)).count == result.count else { throw MochletError.message("Project fields changed during paging.") }
            if let cursor { variables["cursor"] = cursor } else { return result }
        }
        throw MochletError.message("Project exceeds the 500-field limit.")
    }
    private func values(item: GitHubBoardItem, budget: ReadBudget) async throws -> [GitHubBoardValue] {
        var variables = ["id": item.id], cursors = Set<String>(), result: [GitHubBoardValue] = []
        for _ in 0..<5 {
            let data = try await call("query($id:ID!,$cursor:String) { node(id:$id) { ... on ProjectV2Item { id updatedAt fieldValues(first:100,after:$cursor) { nodes { \(Self.value) } \(Self.pageInfo) } } } }", variables: variables, as: Node<Values>.self, budget: budget)
            guard let node = data.node, node.id == item.id, node.updatedAt == item.updatedAt else { throw MochletError.message("A board item changed while reading field values. Refresh again.") }
            let cursor = try next(node.fieldValues, seen: &cursors)
            result += node.fieldValues.nodes.compactMap { $0 }
            guard Set(result.map(\.id)).count == result.count else { throw MochletError.message("Field values changed during paging.") }
            if let cursor { variables["cursor"] = cursor } else { return result }
        }
        throw MochletError.message("Item exceeds the 500-field-value limit.")
    }
    public func snapshot(address: GitHubBoardAddress, binding: GitHubBinding, expectedID: String? = nil) async throws -> GitHubBoardSnapshot {
        let budget = ReadBudget()
        try await identity.verify(binding)
        let query = "query($owner:String!) { owner:\(address.organization ? "organization" : "user")(login:$owner) { projectV2(number:\(address.number)) { \(Self.metadata) } } }"
        let start = try await call(query, variables: ["owner": address.owner], as: OwnerResult.self, budget: budget)
        guard let board = start.owner?.projectV2, expectedID == nil || expectedID == board.id else { throw MochletError.message("Board is unavailable or its identity changed. Bind the intended board explicitly.") }
        let fields = try await fields(id: board.id, budget: budget)
        var variables = ["id": board.id], cursors = Set<String>(), items: [GitHubBoardItem] = [], complete = false
        for _ in 0..<10 {
            let page = try await call("query($id:ID!,$cursor:String) { node(id:$id) { ... on ProjectV2 { id items(first:100,after:$cursor,archivedStates:[ARCHIVED,NOT_ARCHIVED]) { nodes { id isArchived updatedAt type \(Self.content) } \(Self.pageInfo) } } } }", variables: variables, as: Node<Items>.self, budget: budget)
            guard let node = page.node, node.id == board.id else { throw MochletError.message("Board became inaccessible.") }
            let cursor = try next(node.items, seen: &cursors)
            items += node.items.nodes.compactMap { $0 }
            guard Set(items.map(\.id)).count == items.count else { throw MochletError.message("Board membership changed during paging.") }
            if let cursor { variables["cursor"] = cursor } else { complete = true; break }
        }
        guard complete else { throw MochletError.message("Board exceeds the 1,000-item limit. Previous snapshot was preserved.") }
        // Keep native refresh bounded without silently dropping later items or values.
        guard items.count <= 150 else { throw MochletError.message("This personal build supports complete field-value sync for up to 150 board items. Previous snapshot was preserved.") }
        for index in items.indices { items[index].values = try await values(item: items[index], budget: budget) }
        let end = try await call(query, variables: ["owner": address.owner], as: OwnerResult.self, budget: budget)
        guard end.owner?.projectV2 == board, try await self.fields(id: board.id, budget: budget) == fields else { throw MochletError.message("Board metadata or fields changed during sync. Refresh again.") }
        try await identity.verify(binding)
        let snapshot = GitHubBoardSnapshot(binding: binding, address: address, id: board.id, title: board.title, closed: board.closed, updatedAt: board.updatedAt, fields: fields, items: items, fetchedAt: Date())
        guard try JSONEncoder().encode(snapshot).count <= 8_000_000 else { throw MochletError.message("Board snapshot exceeds 8 MB.") }
        return snapshot
    }
    public func verifyItem(_ item: GitHubBoardItem, snapshot: GitHubBoardSnapshot) async throws {
        try await verifySelection(.init(item: item, snapshot: snapshot))
    }
    public func verifySelection(_ selection: GitHubBoardSelection) async throws {
        let item = selection.item
        try await identity.verify(selection.binding)
        let data = try await call("query($id:ID!) { node(id:$id) { ... on ProjectV2Item { id isArchived updatedAt type project { id closed } \(Self.content) } } }", variables: ["id": item.id], as: Node<ItemCheck>.self)
        guard let fresh = data.node, fresh.project.id == selection.boardID, !fresh.project.closed, fresh.id == item.id, !fresh.isArchived,
              fresh.updatedAt == item.updatedAt, fresh.type == item.type, fresh.content == item.content,
              item.canPrepare(binding: selection.binding) else { throw MochletError.message("Board item changed, was archived or belongs to another repository. Refresh and review its destination.") }
        try await identity.verify(selection.binding)
    }
}
