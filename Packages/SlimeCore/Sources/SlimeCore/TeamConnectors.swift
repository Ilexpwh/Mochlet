import Foundation
import CryptoKit

public enum TeamService: String, Codable, Sendable, CaseIterable {
    case slack, lark, feishu, linear
    public var title: String { switch self { case .slack: "Slack"; case .lark: "Lark"; case .feishu: "Feishu"; case .linear: "Linear" } }
    public var readCapability: String { rawValue + ".source.read" }
    var host: String { switch self { case .slack: "slack.com"; case .linear: "api.linear.app"; case .lark: "open.larksuite.com"; case .feishu: "open.feishu.cn" } }
}
public struct TeamReader: Sendable {
    public let service: TeamService
    let token: String
    let http: ConnectorHTTP
    public init(service: TeamService, token: String, http: ConnectorHTTP = .init()) { self.service = service; self.token = token; self.http = http }
    func request(_ path: [String], query: [String: String] = [:], body: JSONValue? = nil) throws -> URLRequest {
        var url = URLComponents(); url.scheme = "https"; url.host = service.host
        url.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }.joined(separator: "/")
        url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        request.setValue((service == .linear ? "" : "Bearer ") + token, forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    func api(_ path: [String], query: [String: String] = [:], body: JSONValue? = nil) async throws -> JSONValue {
        let result = try JSONDecoder().decode(JSONValue.self, from: await http.send(request(path, query: query, body: body)))
        switch service {
        case .slack:
            guard result["ok"] == .bool(true) else { throw MochletError.message("Slack denied this request. Check token permissions, conversation membership and message identity.") }; return result
        case .linear:
            guard result["errors"].array.isEmpty, result["data"] != .null else { throw MochletError.message("Linear returned an incomplete or denied GraphQL result. No partial context was saved.") }; return result["data"]
        case .lark, .feishu:
            guard result["code"] == .number(0), result["data"] != .null else { throw MochletError.message("Lark/Feishu denied this request. Check user-token expiry, app permissions and message visibility.") }; return result["data"]
        }
    }
    func graph(_ query: String, variables: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await api(["graphql"], body: .object(["query": .string(query), "variables": .object(variables)]))
    }
    public func identity() async throws -> ConnectedAccount {
        let remoteID: String, label: String
        switch service {
        case .slack:
            let user = try await api(["api", "auth.test"])
            guard let team = user["team_id"].string, !team.isEmpty, let id = user["user_id"].string, !id.isEmpty else { throw MochletError.message("Slack omitted workspace or user identity.") }
            remoteID = team + ":" + id; label = (user["team"].string ?? team) + " • " + (user["user"].string ?? id)
        case .linear:
            let user = try await graph("query MochletIdentity { viewer { id name } organization { id name } }")
            guard let org = user["organization"]["id"].string, !org.isEmpty, let id = user["viewer"]["id"].string, !id.isEmpty else { throw MochletError.message("Linear omitted organization or user identity.") }
            remoteID = org + ":" + id; label = (user["organization"]["name"].string ?? org) + " • " + (user["viewer"]["name"].string ?? id)
        case .lark, .feishu:
            let user = try await api(["open-apis", "authen", "v1", "user_info"])
            guard let tenant = user["tenant_key"].string, !tenant.isEmpty, let id = user["open_id"].string, !id.isEmpty else { throw MochletError.message("Lark omitted tenant or user identity. Use a user_access_token for the intended app and tenant.") }
            remoteID = tenant + ":" + id; label = (user["name"].string ?? id) + " • " + tenant
        }
        // This is an app capability marker, not a claim about remotely granted OAuth scopes.
        return ConnectedAccount(provider: service.rawValue, remoteID: remoteID, label: label, scopes: [service.readCapability])
    }
    public func read(account: ConnectedAccount, collection: String, objectID: String) async throws -> ConnectedSource {
        guard account.provider == service.rawValue, collection.count <= 256, !objectID.isEmpty, objectID.count <= 256 else { throw MochletError.message("Check the selected connection and source IDs.") }
        let identity = try await identity()
        guard identity.remoteID == account.remoteID else { throw MochletError.message("The token belongs to a different workspace or user. Reconnect the correct account.") }
        switch service {
        case .slack: return try await slackThread(account: account, channel: collection, timestamp: objectID)
        case .linear: return try await linearIssue(account: account, expectedTeam: collection, id: objectID)
        case .lark, .feishu: return try await larkMessage(account: account, expectedChat: collection, id: objectID)
        }
    }
    private func source(account: ConnectedAccount, collection: String, id: String, title: String, rows: JSONValue, url: String, warnings: [String] = []) throws -> ConnectedSource {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(rows)
        guard data.count <= 1_000_000 else { throw MochletError.message("Selected context exceeds 1 MB. Choose a smaller source.") }
        var source = ConnectedSource(accountID: account.id, service: service.rawValue, collection: collection, remoteID: id, title: title, body: rows.formatted, url: url,
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        source.warnings = warnings; return source
    }
    private func slackThread(account: ConnectedAccount, channel: String, timestamp: String) async throws -> ConnectedSource {
        guard channel.range(of: "^[CDG][A-Z0-9]+$", options: .regularExpression) != nil,
              timestamp.range(of: #"^[0-9]+\.[0-9]{6}$"#, options: .regularExpression) != nil else { throw MochletError.message("Use a Slack channel ID and exact parent message timestamp, such as 1730000000.123456.") }
        var query = ["channel": channel, "ts": timestamp, "limit": "100"], messages: [JSONValue] = [], cursors = Set<String>(), ids = Set<String>()
        for page in 0..<10 {
            let response = try await api(["api", "conversations.replies"], query: query)
            for message in response["messages"].array {
                guard let id = message["ts"].string, id == timestamp || message["thread_ts"].string == timestamp else { throw MochletError.message("Slack returned a message outside the selected thread.") }
                if ids.insert(id).inserted { messages.append(message) }
            }
            guard messages.count <= 500 else { throw MochletError.message("Slack thread exceeds 500 messages.") }
            let next = response["response_metadata"]["next_cursor"].string ?? ""
            if next.isEmpty {
                guard response["has_more"] != .bool(true), messages.contains(where: { $0["ts"].string == timestamp }) else { throw MochletError.message("Slack returned incomplete thread context.") }; break
            }
            guard page < 9, cursors.insert(next).inserted else { throw MochletError.message("Slack pagination did not complete. No partial thread was saved.") }
            query["cursor"] = next
        }
        let link = try await api(["api", "chat.getPermalink"], query: ["channel": channel, "message_ts": timestamp])
        guard link["channel"].string == channel, let url = link["permalink"].string, let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.hasSuffix(".slack.com") == true else { throw MochletError.message("Slack did not provide a source link.") }
        let fields = ["ts", "thread_ts", "user", "bot_id", "text", "edited", "subtype"]
        let rows = messages.map { row in JSONValue.object(Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0]) })) }
        let title = String((messages.first?["text"].string ?? "Slack thread").prefix(100))
        return try source(account: account, collection: channel, id: timestamp, title: title, rows: .array(rows), url: url, warnings: ["Text and sender IDs only. Files, blocks, links and linked content are not downloaded or analyzed."])
    }
    private func linearIssue(account: ConnectedAccount, expectedTeam: String, id: String) async throws -> ConnectedSource {
        var comments: [JSONValue] = [], cursor: JSONValue = .null, seen = Set<String>(), issue: JSONValue = .null, issueID: String?
        for page in 0..<10 {
            let result = try await graph("query MochletIssue($id: String!, $after: String) { issue(id: $id) { id identifier title description url updatedAt team { id name } state { name } comments(first: 50, after: $after) { nodes { id body updatedAt user { id name } url } pageInfo { hasNextPage endCursor } } } }", variables: ["id": .string(id), "after": cursor])
            let current = result["issue"]
            guard let currentID = current["id"].string, issueID == nil || issueID == currentID else { throw MochletError.message("Linear issue identity changed during paging.") }
            guard currentID.caseInsensitiveCompare(id) == .orderedSame || current["identifier"].string == id else { throw MochletError.message("Linear returned a different issue.") }
            if issueID != nil, current["updatedAt"] != issue["updatedAt"] { throw MochletError.message("Linear issue changed during paging. Refresh it again.") }
            guard case .array = current["comments"]["nodes"] else { throw MochletError.message("Linear omitted comment visibility.") }
            issueID = currentID; issue = current; comments += current["comments"]["nodes"].array
            guard comments.count <= 500 else { throw MochletError.message("Linear issue exceeds 500 comments.") }
            let info = current["comments"]["pageInfo"]
            if info["hasNextPage"] == .bool(false) { break }
            guard page < 9, let next = info["endCursor"].string, !next.isEmpty, seen.insert(next).inserted else { throw MochletError.message("Linear comments could not be fully retrieved.") }
            cursor = .string(next)
        }
        guard let issueID, let team = issue["team"]["id"].string, expectedTeam.isEmpty || team == expectedTeam, let url = issue["url"].string else { throw MochletError.message("Linear omitted issue metadata.") }
        var fields = Dictionary(uniqueKeysWithValues: ["id", "identifier", "title", "description", "updatedAt", "team", "state"].map { ($0, issue[$0]) })
        fields["comments"] = .array(comments)
        return try source(account: account, collection: team, id: issueID, title: (issue["identifier"].string ?? "Issue") + " • " + (issue["title"].string ?? ""), rows: .object(fields), url: url, warnings: ["Attachments and linked documents are not downloaded. Comment bodies remain untrusted source text."])
    }
    private func larkMessage(account: ConnectedAccount, expectedChat: String, id: String) async throws -> ConnectedSource {
        guard id.range(of: "^om_[A-Za-z0-9]+$", options: .regularExpression) != nil else { throw MochletError.message("Use a Lark message ID beginning with om_.") }
        let result = try await api(["open-apis", "im", "v1", "messages", id])
        guard let root = result["items"].array.first(where: { $0["message_id"].string == id }), root["deleted"] != .bool(true),
              let chat = root["chat_id"].string, expectedChat.isEmpty || expectedChat == chat else { throw MochletError.message("Message is unavailable or belongs to another chat.") }
        var messages = [root], cursors = Set<String>()
        if let thread = root["thread_id"].string, !thread.isEmpty {
            var query = ["container_id_type": "thread", "container_id": thread, "page_size": "50", "sort_type": "ByCreateTimeAsc"]
            for page in 0..<10 {
                let response = try await api(["open-apis", "im", "v1", "messages"], query: query)
                for message in response["items"].array {
                    guard message["chat_id"].string == chat, message["thread_id"].string == thread else { throw MochletError.message("Lark returned a message outside the selected thread.") }
                    if message["deleted"] != .bool(true), !messages.contains(where: { $0["message_id"] == message["message_id"] }) { messages.append(message) }
                }
                guard messages.count <= 500 else { throw MochletError.message("Lark thread exceeds 500 messages.") }
                if response["has_more"] == .bool(false) { break }
                guard page < 9, let next = response["page_token"].string, !next.isEmpty, cursors.insert(next).inserted else { throw MochletError.message("Lark thread pagination did not complete.") }; query["page_token"] = next
            }
        }
        let canonicalID = root["root_id"].string.flatMap { $0.isEmpty ? nil : $0 } ?? id
        guard messages.contains(where: { $0["message_id"].string == canonicalID }) else { throw MochletError.message("The thread root is not visible; complete context could not be retrieved.") }
        let fields = ["message_id", "root_id", "parent_id", "thread_id", "msg_type", "sender", "create_time", "update_time", "body"]
        let rows = messages.map { row in JSONValue.object(Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0]) })) }
        return try source(account: account, collection: chat, id: canonicalID, title: service.title + " message " + canonicalID, rows: .array(rows), url: "https://" + service.host + "/open-apis/im/v1/messages/" + canonicalID,
            warnings: ["Source locator is the authenticated message API. Rich-message JSON is shown as returned; files, cards and linked content are not downloaded."])
    }
}

public actor TokenConnections {
    let store: Store
    let credentials = CredentialStore()
    private var busy = false
    public init(store: Store) { self.store = store }
    public func connect(service: TeamService, token: String) async throws -> ConnectedAccount {
        guard !busy else { throw MochletError.message("Finish the current connection operation first.") }; busy = true; defer { busy = false }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }), token.count <= 8192 else { throw MochletError.message("Enter a valid service token without spaces.") }
        var account = try await TeamReader(service: service, token: token).identity()
        if let old = try await store.connections().first(where: { $0.provider == account.provider && $0.remoteID == account.remoteID }) { account.id = old.id; account.projectIDs = old.projectIDs }
        try Task.checkCancellation()
        let key = "connector." + account.id, previous = try await credentials.read("connector." + account.id)
        try await credentials.save(Data(token.utf8), account: key)
        do { try await store.saveConnection(account) }
        catch { if let previous { try await credentials.save(previous, account: key) } else { try await credentials.remove(key) }; throw error }
        return account
    }
    public func reader(_ account: ConnectedAccount) async throws -> TeamReader {
        guard let service = TeamService(rawValue: account.provider), try await store.connections().contains(account),
              let data = try await credentials.read("connector." + account.id), let token = String(data: data, encoding: .utf8) else { throw MochletError.message("Reconnect this account with a current token.") }
        return TeamReader(service: service, token: token)
    }
    public func disconnect(_ account: ConnectedAccount) async throws {
        guard !busy else { throw MochletError.message("Finish the current connection operation first.") }; busy = true; defer { busy = false }
        try await store.disconnect(account.id); try await credentials.remove("connector." + account.id)
    }
}
