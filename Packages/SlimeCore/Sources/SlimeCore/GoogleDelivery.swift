import Foundation

public struct GoogleDelivery: Sendable {
    let account: ConnectedAccount
    let reader: GoogleReader
    let http: ConnectorHTTP
    public init(account: ConnectedAccount, token: String, http: ConnectorHTTP = .init()) {
        self.account = account; self.http = http; reader = GoogleReader(account: account, token: token, http: http)
    }
    public static func addresses(_ text: String) throws -> [String] {
        let addresses = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard addresses.count <= 50, addresses.allSatisfy({ $0.utf8.count <= 254 && $0.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }) else {
            throw MochletError.message("Use comma-separated email addresses without display names or line breaks (at most 50).")
        }
        return addresses
    }
    private static func encodedWords(_ text: String) -> String {
        var parts: [String] = [], part = ""
        for scalar in text.unicodeScalars {
            if part.utf8.count + scalar.utf8.count > 42 { parts.append(part); part = "" }
            part.unicodeScalars.append(scalar)
        }
        if !part.isEmpty { parts.append(part) }
        return parts.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }
    public func prepareReply(projectID: String, threadID: String, to: String, cc: String, bcc: String, body: String, saveDraft: Bool) async throws -> DeliveryDraft {
        let kind: DeliveryKind = saveDraft ? .gmailDraft : .gmailSend
        guard account.scopes.contains(kind.scope) else { throw MochletError.message("Reconnect with the selected Gmail write permission first.") }
        try await reader.verify(scope: GoogleScope.mail)
        let recipients = try Self.addresses(to), copies = try Self.addresses(cc), blind = try Self.addresses(bcc)
        guard !recipients.isEmpty, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.utf8.count <= 200_000 else { throw MochletError.message("Choose a recipient and a message of at most 200 KB.") }
        _ = try Self.addresses(account.label)
        let thread = try await reader.get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "threads", threadID], ["format": "metadata"])
        guard thread["id"].string == threadID, let latest = thread["messages"].array.last else { throw MochletError.message("The reply thread is unavailable.") }
        let headers = latest["payload"]["headers"].array
        func header(_ name: String) -> String { headers.first { $0["name"].string?.lowercased() == name }?["value"].string ?? "" }
        let originalID = header("message-id"), subject = header("subject")
        guard originalID.range(of: #"^<[^<>\s]+@[^<>\s]+>$"#, options: .regularExpression) != nil, !subject.contains("\r"), !subject.contains("\n"), subject.utf8.count <= 1000 else { throw MochletError.message("This thread lacks safe reply headers. Reply in Gmail instead.") }
        let actionID = UUID().uuidString.lowercased(), messageID = "<mochlet-" + UUID().uuidString.lowercased() + "@mochlet.local>"
        var lines = ["From: " + account.label, "To: " + recipients.joined(separator: ", ")]
        if !copies.isEmpty { lines.append("Cc: " + copies.joined(separator: ", ")) }
        if !blind.isEmpty { lines.append("Bcc: " + blind.joined(separator: ", ")) }
        lines += ["Subject: " + Self.encodedWords(subject), "Message-ID: " + messageID, "In-Reply-To: " + originalID, "References: " + originalID,
                  "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64", "",
                  Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])]
        let raw = Data(lines.joined(separator: "\r\n").utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let payload: JSONValue = .object(["raw": .string(raw), "threadId": .string(threadID), "mochletMessageID": .string(messageID)])
        let preview = "\(kind.title)\nFrom: \(account.label)\nTo: \(recipients.joined(separator: ", "))\nCc: \(copies.joined(separator: ", "))\nBcc: \(blind.joined(separator: ", "))\nSubject: \(subject)\nThread: \(threadID)\nAttachments: none\n\n\(body)"
        return DeliveryDraft(id: actionID, account: account, projectID: projectID, kind: kind, collection: "threads", remoteID: threadID, expectedRevision: thread["historyId"].string ?? "", payload: payload, preview: preview)
    }
    public func prepareEvent(projectID: String, calendarID: String, source: ConnectedSource?, kind: DeliveryKind, title: String,
                             start: Date, end: Date, timeZone: String, attendees: String, notifications: String) async throws -> DeliveryDraft {
        guard [.calendarCreate, .calendarUpdate, .calendarCancel].contains(kind), account.scopes.contains(GoogleScope.calendarWrite),
              ["all", "externalOnly", "none"].contains(notifications), !calendarID.isEmpty, TimeZone(identifier: timeZone) != nil else { throw MochletError.message("Check calendar write permission, calendar, time zone and notification choice.") }
        try await reader.verify(scope: GoogleScope.calendar)
        var remoteID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), revision = "", occurrence = "New single event"
        let actionID = UUID().uuidString.lowercased()
        var current: JSONValue = .null
        if kind != .calendarCreate {
            guard let source, source.accountID == account.id, source.collection == calendarID, source.service == "calendar" else { throw MochletError.message("Select the event in this account and calendar first.") }
            current = try await reader.get("www.googleapis.com", ["calendar", "v3", "calendars", calendarID, "events", source.remoteID])
            guard current["id"].string == source.remoteID, current["status"].string != "cancelled", let etag = current["etag"].string, !etag.isEmpty,
                  current["recurrence"].array.isEmpty else { throw MochletError.message("Select a current individual event or occurrence. Editing an entire recurring series is not supported here.") }
            remoteID = source.remoteID; revision = etag
            occurrence = current["recurringEventId"].string == nil ? "Single event" : "Only this occurrence of " + (current["recurringEventId"].string ?? "")
        }
        var event: [String: JSONValue] = [:]
        if kind != .calendarCancel {
            guard end > start, end.timeIntervalSince(start) <= 32 * 86400, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1000 else { throw MochletError.message("Choose a title and a positive event duration of at most 32 days.") }
            let guests = try Self.addresses(attendees)
            var privateProperties: [String: JSONValue] = [:]
            if case .object(let properties) = current["extendedProperties"]["private"] { privateProperties = properties }
            privateProperties["mochletAction"] = .string(actionID)
            event = ["summary": .string(title), "start": .object(["dateTime": .string(start.ISO8601Format()), "timeZone": .string(timeZone)]),
                     "end": .object(["dateTime": .string(end.ISO8601Format()), "timeZone": .string(timeZone)]),
                     "attendees": .array(guests.map { .object(["email": .string($0)]) }),
                     "extendedProperties": .object(["private": .object(privateProperties)])]
            if kind == .calendarCreate { event["id"] = .string(remoteID) }
        }
        let payload: JSONValue = .object(["event": .object(event), "sendUpdates": .string(notifications)])
        let before = current == .null ? "" : "\nCurrent event:\n" + current.formatted
        let preview = "\(kind.title)\nAccount: \(account.label)\nCalendar: \(calendarID)\n\(occurrence)\nNotification choice: \(notifications) (Google may still send some mail)\n\(kind == .calendarCancel ? "Cancel the selected event." : "Proposed event:\n" + JSONValue.object(event).formatted)\(before)"
        return DeliveryDraft(id: actionID, account: account, projectID: projectID, kind: kind, collection: calendarID, remoteID: remoteID, expectedRevision: revision, payload: payload, preview: preview)
    }
    public func execute(_ draft: DeliveryDraft, store: Store) async throws {
        guard draft.accountID == account.id, draft.accountGeneration == account.generation else { throw MochletError.message("This preview belongs to a different account state.") }
        try await reader.verify(scope: draft.kind.scope)
        var request: URLRequest
        switch draft.kind {
        case .gmailSend, .gmailDraft:
            let thread = try await reader.get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "threads", draft.remoteID], ["format": "metadata"])
            guard thread["historyId"].string == draft.expectedRevision else { throw MochletError.message("The email thread changed. Prepare a new reply preview.") }
            request = reader.request(host: "gmail.googleapis.com", path: ["gmail", "v1", "users", "me"] + (draft.kind == .gmailSend ? ["messages", "send"] : ["drafts"]))
            let message: JSONValue = .object(["raw": draft.payload["raw"], "threadId": draft.payload["threadId"]])
            request.httpBody = try JSONEncoder().encode(draft.kind == .gmailSend ? message : .object(["message": message]))
            request.httpMethod = "POST"
        default:
            let path = ["calendar", "v3", "calendars", draft.collection, "events"]
            if draft.kind != .calendarCreate {
                let current = try await reader.get("www.googleapis.com", path + [draft.remoteID])
                guard current["etag"].string == draft.expectedRevision, current["status"].string != "cancelled" else { throw MochletError.message("The event changed. Review a fresh preview.") }
            }
            if draft.kind != .calendarCancel {
                let event = draft.payload["event"]
                guard let start = event["start"]["dateTime"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }),
                      let end = event["end"]["dateTime"].string.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { throw MochletError.message("The event time is invalid.") }
                let availability = try await reader.freeBusy(calendarID: draft.collection, from: start, to: end)
                if !availability["busy"].array.isEmpty {
                    if draft.kind == .calendarCreate { throw MochletError.message("This calendar is busy in the proposed interval. Choose another time and prepare again.") }
                    let events = try await reader.agenda(calendarID: draft.collection, from: start, to: end)
                    guard !events.isEmpty else { throw MochletError.message("Busy time could not be attributed to visible events. Review availability in Google Calendar.") }
                    for event in events where event.remoteID != draft.remoteID {
                        let details = try JSONDecoder().decode(JSONValue.self, from: Data(event.body.utf8))
                        guard details["transparency"].string == "transparent" else { throw MochletError.message("Another event overlaps the proposed time. Choose another interval.") }
                    }
                }
            }
            request = reader.request(host: "www.googleapis.com", path: path + (draft.kind == .calendarCreate ? [] : [draft.remoteID]), query: ["sendUpdates": draft.payload["sendUpdates"].string ?? "none"])
            request.httpMethod = draft.kind == .calendarCreate ? "POST" : draft.kind == .calendarUpdate ? "PATCH" : "DELETE"
            if draft.kind != .calendarCreate { request.setValue(draft.expectedRevision, forHTTPHeaderField: "If-Match") }
            if draft.kind != .calendarCancel { request.httpBody = try JSONEncoder().encode(draft.payload["event"]) }
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Task.checkCancellation(); try await store.claimDelivery(draft)
        try await transmitClaimed(draft, request: request, store: store)
    }
    func transmitClaimed(_ draft: DeliveryDraft, request: URLRequest, store: Store) async throws {
        do { try Task.checkCancellation() }
        catch {
            try await store.finishDelivery(draft.id, state: "rejected", receipt: .object(["reason": .string("Cancelled before transport invocation; no write was sent.")]))
            throw error
        }
        do {
            let data = try await http.send(request)
            let receipt = data.isEmpty ? JSONValue.object(["id": .string(draft.remoteID), "status": .string("cancelled")]) : try JSONDecoder().decode(JSONValue.self, from: data)
            guard receipt["id"].string != nil else { throw MochletError.message("Google returned no delivery identity. Reconcile before taking further action.") }
            try await store.finishDelivery(draft.id, state: "delivered", receipt: receipt)
        } catch {
            if case ConnectorError.http(let status) = error, [400, 401, 403, 404, 410, 412, 422].contains(status) {
                try await store.finishDelivery(draft.id, state: "rejected", receipt: .object(["httpStatus": .number(Double(status))]))
            }
            throw error
        }
    }
    public func reconcile(_ record: DeliveryRecord, store: Store) async throws {
        let draft = record.draft
        guard record.state == "uncertain", draft.accountID == account.id else { throw MochletError.message("Only an uncertain action for this account can be reconciled.") }
        let receipt: JSONValue
        switch draft.kind {
        case .gmailSend, .gmailDraft:
            try await reader.verify(scope: GoogleScope.mail)
            guard let messageID = draft.payload["mochletMessageID"].string else { throw MochletError.message("Message reconciliation identity is missing.") }
            let messages = try await reader.get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "messages"], ["q": (draft.kind == .gmailSend ? "in:sent " : "in:drafts ") + "rfc822msgid:" + messageID, "maxResults": "2"])
            guard messages["messages"].array.count == 1, let id = messages["messages"].array.first?["id"].string else { throw MochletError.message("No unique remote result was found. Delivery remains uncertain; it was not retried.") }
            let message = try await reader.get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "messages", id], ["format": "metadata"])
            let headers = message["payload"]["headers"].array
            guard headers.contains(where: { $0["name"].string?.lowercased() == "message-id" && $0["value"].string == messageID }),
                  message["threadId"].string == draft.remoteID,
                  message["labelIds"].array.contains(.string(draft.kind == .gmailSend ? "SENT" : "DRAFT")) else { throw MochletError.message("Remote evidence does not match this action; delivery remains uncertain.") }
            receipt = .object(["id": .string(id), "threadId": .string(draft.remoteID), "reconciled": .bool(true)])
        default:
            try await reader.verify(scope: GoogleScope.calendar)
            let event = try await reader.get("www.googleapis.com", ["calendar", "v3", "calendars", draft.collection, "events", draft.remoteID])
            guard draft.kind == .calendarCancel ? event["status"].string == "cancelled" : event["extendedProperties"]["private"]["mochletAction"].string == draft.id else {
                throw MochletError.message("No matching remote event outcome was found. The action remains uncertain and was not retried.")
            }
            receipt = event
        }
        try await store.finishDelivery(draft.id, state: "delivered", receipt: receipt)
    }
}
