import Foundation

/// Explicit, reviewed replies. No retry path can invoke the write transport twice.
public struct TeamDelivery: Sendable {
    public let account: ConnectedAccount
    let reader: TeamReader
    public init(account: ConnectedAccount, reader: TeamReader) { self.account = account; self.reader = reader }
    var kind: DeliveryKind {
        switch reader.service { case .slack: .slackReply; case .lark: .larkReply; case .feishu: .feishuReply; case .linear: .linearComment }
    }
    public func prepare(projectID: String, source: ConnectedSource, body: String) async throws -> DeliveryDraft {
        guard account.provider == reader.service.rawValue, account.scopes.contains(kind.scope), account.projectIDs.contains(projectID),
              source.accountID == account.id, source.service == account.provider else { throw MochletError.message("Enable reviewed replies and bind this account to the selected project first.") }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 3500, !text.contains("\0") else { throw MochletError.message("Write a reply of at most 3,500 UTF-8 bytes.") }
        // Rich mentions are intentionally not accepted by the initial plain-text reply flow.
        guard !text.lowercased().contains("<at ") else { throw MochletError.message("Use plain text without Lark mention markup.") }
        let fresh = try await reader.read(account: account, collection: source.collection, objectID: source.remoteID)
        guard fresh.revision == source.revision else { throw MochletError.message("The source changed. Read it again before preparing a reply.") }
        let id = UUID().uuidString.lowercased()
        let message = reader.service == .linear ? text : text + "\n\nMochlet delivery: " + id
        let wire = reader.service == .slack ? message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") : message
        let preview = "\(kind.title)\nAccount: \(account.label)\nWorkspace/user: \(account.remoteID)\nProject: \(projectID)\nDestination: \(fresh.collection) / \(fresh.remoteID)\n\(fresh.title)\nService notification settings apply. No attachments.\n\n\(message)"
        return DeliveryDraft(id: id, account: account, projectID: projectID, kind: kind, collection: fresh.collection, remoteID: fresh.remoteID,
                             expectedRevision: fresh.revision, payload: .object(["text": .string(wire), "remoteAccountID": .string(account.remoteID)]), preview: preview)
    }
    private func validate(_ draft: DeliveryDraft, store: Store) async throws {
        guard draft.kind == kind, draft.accountID == account.id, draft.accountGeneration == account.generation,
              account.provider == reader.service.rawValue, account.scopes.contains(kind.scope), account.projectIDs.contains(draft.projectID),
              try await store.connections().contains(account) else { throw MochletError.message("The account or project permission changed. Prepare a new preview.") }
    }
    public func execute(_ draft: DeliveryDraft, store: Store) async throws {
        try await validate(draft, store: store)
        let fresh = try await reader.read(account: account, collection: draft.collection, objectID: draft.remoteID)
        guard fresh.revision == draft.expectedRevision else { throw MochletError.message("The source changed after review. Read it again and prepare a new preview.") }
        let request: URLRequest
        switch reader.service {
        case .slack:
            request = try reader.request(["api", "chat.postMessage"], body: .object(["channel": .string(draft.collection), "thread_ts": .string(draft.remoteID), "text": draft.payload["text"],
                "reply_broadcast": .bool(false), "mrkdwn": .bool(false), "parse": .string("none"), "unfurl_links": .bool(false), "unfurl_media": .bool(false)]))
        case .lark, .feishu:
            let content = String(decoding: try JSONEncoder().encode(JSONValue.object(["text": draft.payload["text"]])), as: UTF8.self)
            request = try reader.request(["open-apis", "im", "v1", "messages", draft.remoteID, "reply"], body: .object(["msg_type": .string("text"), "content": .string(content), "reply_in_thread": .bool(true), "uuid": .string(draft.id)]))
        case .linear:
            request = try reader.request(["graphql"], body: .object(["query": .string("mutation MochletReply($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id body issue { id } user { id } } } }"),
                "variables": .object(["input": .object(["id": .string(draft.id), "issueId": .string(draft.remoteID), "body": draft.payload["text"], "createOnSyncedSlackThread": .bool(false)])])]))
        }
        try Task.checkCancellation(); try await store.claimDelivery(draft)
        do { try Task.checkCancellation() }
        catch {
            try await store.finishDelivery(draft.id, state: "rejected", receipt: .object(["reason": .string("Cancelled before transport invocation.")]))
            throw error
        }
        let data: Data
        do { data = try await reader.http.send(request) }
        catch {
            if case ConnectorError.http(let status) = error, [400, 401, 403, 404, 410, 412, 422, 429].contains(status) {
                try await store.finishDelivery(draft.id, state: "rejected", receipt: .object(["httpStatus": .number(Double(status))]))
            }
            throw error
        }
        let result = try JSONDecoder().decode(JSONValue.self, from: data)
        if reader.service == .slack, result["ok"] == .bool(false), let code = result["error"].string,
           ["missing_scope", "not_authed", "invalid_auth", "token_revoked", "account_inactive", "channel_not_found", "not_in_channel", "is_archived", "restricted_action", "no_text", "msg_too_long", "rate_limited", "ratelimited"].contains(code) {
            try await store.finishDelivery(draft.id, state: "rejected", receipt: .object(["serviceError": .string(code)]))
            throw MochletError.message("Slack rejected the reply: \(code). No reply was delivered. Correct the permission or destination and prepare a new preview.")
        }
        let receipt: JSONValue
        switch reader.service {
        case .slack:
            guard result["ok"] == .bool(true), result["channel"].string == draft.collection,
                  let id = result["ts"].string, !id.isEmpty, matches(result["message"], draft: draft) else { throw uncertain() }
            receipt = .object(["id": .string(id)])
        case .lark, .feishu:
            let row = result["data"]
            guard result["code"] == .number(0), row["chat_id"].string == draft.collection, matches(row, draft: draft),
                  let id = row["message_id"].string, !id.isEmpty else { throw uncertain() }
            receipt = .object(["id": .string(id)])
        case .linear:
            let row = result["data"]["commentCreate"]["comment"]
            guard result["errors"].array.isEmpty, result["data"]["commentCreate"]["success"] == .bool(true),
                  row["issue"]["id"].string == draft.remoteID, matches(row, draft: draft) else { throw uncertain() }
            receipt = .object(["id": .string(draft.id)])
        }
        try await store.finishDelivery(draft.id, state: "delivered", receipt: receipt)
    }
    public func reconcile(_ record: DeliveryRecord, store: Store) async throws {
        let draft = record.draft
        guard record.state == "uncertain" else { throw uncertain() }
        // Reconciliation is read-only and must survive token rotation or removal of write permission.
        // Current project/read access and the original remote user remain mandatory.
        guard draft.kind == kind, draft.accountID == account.id, draft.payload["remoteAccountID"].string == account.remoteID,
              account.provider == reader.service.rawValue, account.scopes.contains(reader.service.readCapability),
              account.projectIDs.contains(draft.projectID), try await store.connections().contains(account) else { throw uncertain() }
        let source = try await reader.read(account: account, collection: draft.collection, objectID: draft.remoteID)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(source.body.utf8))
        let rows = reader.service == .linear ? json["comments"].array : json.array
        let matching = rows.filter { matches($0, draft: draft) }
        guard matching.count == 1 else { throw uncertain() }
        let row = matching[0], id = reader.service == .slack ? row["ts"] : reader.service == .linear ? row["id"] : row["message_id"]
        guard let remoteID = id.string, !remoteID.isEmpty else { throw uncertain() }
        try await store.finishDelivery(draft.id, state: "delivered", receipt: .object(["id": .string(remoteID), "reconciled": .bool(true)]))
    }
    private func matches(_ row: JSONValue, draft: DeliveryDraft) -> Bool {
        guard let user = account.remoteID.split(separator: ":").last.map(String.init) else { return false }
        switch reader.service {
        case .slack: return row["thread_ts"].string == draft.remoteID && row["user"].string == user && row["text"] == draft.payload["text"]
        case .linear: return row["id"].string == draft.id && row["user"]["id"].string == user && row["body"] == draft.payload["text"]
        case .lark, .feishu:
            guard row["sender"]["id"].string == user, row["sender"]["id_type"].string == "open_id",
                  row["root_id"].string == draft.remoteID || row["parent_id"].string == draft.remoteID,
                  let content = row["body"]["content"].string.flatMap({ try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }) else { return false }
            return content["text"] == draft.payload["text"]
        }
    }
    private func uncertain() -> MochletError { .message("No unique matching delivery was confirmed. The action remains uncertain and will not be sent again. Inspect the service before proceeding.") }
}
