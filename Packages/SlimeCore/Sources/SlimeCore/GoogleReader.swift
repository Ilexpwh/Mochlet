import Foundation

public struct GoogleReader: Sendable {
    public let account: ConnectedAccount
    private let token: String
    private let http: ConnectorHTTP
    public init(account: ConnectedAccount, token: String, http: ConnectorHTTP = .init()) { self.account = account; self.token = token; self.http = http }
    func request(host: String, path: [String], query: [String: String] = [:]) -> URLRequest {
        var url = URLComponents(); url.scheme = "https"; url.host = host
        url.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }.joined(separator: "/")
        url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
    func get(_ host: String, _ path: [String], _ query: [String: String] = [:]) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await http.send(request(host: host, path: path, query: query)))
    }
    public func verify(scope: String) async throws {
        guard account.provider == "google", account.scopes.contains(scope) else { throw MochletError.message("This Google permission was not granted.") }
        let user = try await get("openidconnect.googleapis.com", ["v1", "userinfo"])
        guard user["sub"].string == account.remoteID else { throw MochletError.message("Google returned a different account. Disconnect and sign in again.") }
    }
    func pages(_ host: String, _ path: [String], _ query: [String: String], field: String, limit: Int = 500) async throws -> [JSONValue] {
        var query = query; var values: [JSONValue] = []; var seen = Set<String>()
        for _ in 0..<10 {
            let page = try await get(host, path, query)
            values += page[field].array
            guard values.count <= limit else { throw MochletError.message("This result is too large. Narrow the query or time range.") }
            guard let next = page["nextPageToken"].string, !next.isEmpty else { return values }
            guard seen.insert(next).inserted else { throw MochletError.message("Google repeated a page token. Previous cached results remain available.") }
            query["pageToken"] = next
        }
        throw MochletError.message("Google result exceeded the paging limit. Narrow the query.")
    }
    public func mail(query: String) async throws -> [ConnectedSource] {
        try await verify(scope: GoogleScope.mail)
        let rows = try await pages("gmail.googleapis.com", ["gmail", "v1", "users", "me", "threads"], ["q": query, "maxResults": "25"], field: "threads", limit: 100)
        return try rows.map { row in
            guard let id = row["id"].string else { throw MochletError.message("Google omitted a thread identity.") }
            var source = ConnectedSource(accountID: account.id, service: "gmail", collection: "threads", remoteID: id, title: String((row["snippet"].string ?? "Email thread").prefix(100)), body: row["snippet"].string ?? "", url: mailURL(id), revision: row["historyId"].string ?? "")
            source.warnings = ["Search preview only. Read the thread before summarizing or capturing it."]; return source
        }
    }
    private func mailURL(_ id: String) -> String {
        var url = URLComponents(string: "https://mail.google.com/mail/u/")!
        url.queryItems = [.init(name: "authuser", value: account.label)]; url.fragment = "all/" + id; return url.url!.absoluteString
    }
    public func thread(_ id: String) async throws -> ConnectedSource {
        try await verify(scope: GoogleScope.mail)
        let value = try await get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "threads", id], ["format": "full"])
        guard value["id"].string == id, value["messages"].array.count <= 100 else { throw MochletError.message("Thread identity or size is invalid.") }
        var text: [String] = []; var warnings: [String] = []; var title = "Email thread"
        for message in value["messages"].array {
            let headers = message["payload"]["headers"].array
            func header(_ name: String) -> String { headers.first { $0["name"].string?.lowercased() == name }?["value"].string ?? "" }
            if !header("subject").isEmpty { title = header("subject") }
            let body = try Self.mailBody(message["payload"], warnings: &warnings)
            if body.isEmpty { warnings.append("Message \(message["id"].string ?? "unknown"): no supported UTF-8 plain text; showing snippet only.") }
            text.append("Message \(message["id"].string ?? "unknown")\nFrom: \(header("from"))\nDate: \(header("date"))\nSubject: \(header("subject"))\n\(body.isEmpty ? message["snippet"].string ?? "" : body)")
        }
        var source = ConnectedSource(accountID: account.id, service: "gmail", collection: "threads", remoteID: id, title: title, body: text.joined(separator: "\n\n"), url: mailURL(id), revision: value["historyId"].string ?? "")
        guard source.body.utf8.count <= 1_000_000 else { throw MochletError.message("Thread text exceeds the local limit.") }
        source.warnings = Array(Set(warnings)).sorted(); return source
    }
    public static func mailBody(_ part: JSONValue, warnings: inout [String], depth: Int = 0) throws -> String {
        guard depth < 20, part["parts"].array.count <= 200 else { throw MochletError.message("Mail MIME nesting exceeds the local limit.") }
        if let filename = part["filename"].string, !filename.isEmpty { warnings.append("Attachment not downloaded: " + filename); return "" }
        if part["mimeType"].string == "text/plain", let encoded = part["body"]["data"].string {
            let normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let data = Data(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)), let text = String(data: data, encoding: .utf8) else { warnings.append("A text part could not be decoded as UTF-8."); return "" }
            return text
        }
        return try part["parts"].array.map { try mailBody($0, warnings: &warnings, depth: depth + 1) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    public func calendars() async throws -> [JSONValue] {
        try await verify(scope: GoogleScope.calendar)
        return try await pages("www.googleapis.com", ["calendar", "v3", "users", "me", "calendarList"], ["maxResults": "100"], field: "items")
    }
    public func agenda(calendarID: String, from: Date, to: Date) async throws -> [ConnectedSource] {
        guard to > from, to.timeIntervalSince(from) <= 32 * 86400 else { throw MochletError.message("Choose an agenda range of at most 32 days.") }
        try await verify(scope: GoogleScope.calendar)
        let rows = try await pages("www.googleapis.com", ["calendar", "v3", "calendars", calendarID, "events"], ["timeMin": from.ISO8601Format(), "timeMax": to.ISO8601Format(), "singleEvents": "true", "orderBy": "startTime", "showDeleted": "false", "maxResults": "100"], field: "items")
        var ids = Set<String>()
        return try rows.filter { $0["status"].string != "cancelled" }.compactMap { row in
            guard let id = row["id"].string else { throw MochletError.message("Calendar event identity is missing.") }
            guard ids.insert(id).inserted else { return nil }
            return try calendarSource(row, calendarID: calendarID)
        }
    }
    public func freeBusy(calendarID: String, from: Date, to: Date) async throws -> JSONValue {
        guard !calendarID.isEmpty, to > from, to.timeIntervalSince(from) <= 32 * 86400 else { throw MochletError.message("Choose a calendar and a range of at most 32 days.") }
        try await verify(scope: GoogleScope.calendar)
        var request = request(host: "www.googleapis.com", path: ["calendar", "v3", "freeBusy"])
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["timeMin": .string(from.ISO8601Format()), "timeMax": .string(to.ISO8601Format()), "items": .array([.object(["id": .string(calendarID)])])]))
        let response = try JSONDecoder().decode(JSONValue.self, from: await http.send(request))
        let result = response["calendars"][calendarID]
        guard result != .null, result["errors"].array.isEmpty, case .array = result["busy"] else {
            throw MochletError.message("Availability is unknown for this calendar. Missing access is not free time.")
        }
        return result
    }
    public func drive(query: String) async throws -> [ConnectedSource] {
        try await verify(scope: GoogleScope.drive)
        let rows = try await pages("www.googleapis.com", ["drive", "v3", "files"],
            ["q": "trashed = false" + (query.isEmpty ? "" : " and (" + query + ")"), "pageSize": "50",
             "fields": "nextPageToken,files(id,name,mimeType,modifiedTime,webViewLink)", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"], field: "files", limit: 200)
        return try rows.map { row in
            guard let id = row["id"].string else { throw MochletError.message("Drive omitted a file identity.") }
            var source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: id,
                title: row["name"].string ?? "Drive file", body: row["mimeType"].string ?? "", url: row["webViewLink"].string ?? "https://drive.google.com/file/d/" + id,
                revision: row["modifiedTime"].string ?? "")
            source.warnings = ["Metadata only. Read the selected file before using its content."]; return source
        }
    }
    public func driveFile(_ id: String) async throws -> ConnectedSource {
        try await verify(scope: GoogleScope.drive)
        let path = ["drive", "v3", "files", id]
        let fields = ["fields": "id,name,mimeType,modifiedTime,webViewLink,trashed,capabilities(canDownload)", "supportsAllDrives": "true"]
        let metadata = try await get("www.googleapis.com", path, fields)
        guard metadata["id"].string == id, metadata["trashed"] != .bool(true), metadata["capabilities"]["canDownload"] == .bool(true) else {
            throw MochletError.message("This Drive file is missing, trashed, or cannot be downloaded by this account.")
        }
        let type = metadata["mimeType"].string ?? ""
        var warnings: [String] = []
        let contentRequest: URLRequest
        switch type {
        case "application/vnd.google-apps.document", "application/vnd.google-apps.presentation":
            contentRequest = request(host: "www.googleapis.com", path: path + ["export"], query: ["mimeType": "text/plain"])
            warnings = ["Plain-text export. Images, layout, and other non-text content are not analyzed."]
        case "application/vnd.google-apps.spreadsheet":
            contentRequest = request(host: "www.googleapis.com", path: path + ["export"], query: ["mimeType": "text/csv"])
            warnings = ["CSV export contains only the first sheet. Other sheets, formulas, and formatting are not analyzed."]
        default:
            guard type.hasPrefix("text/") || ["application/json", "application/xml"].contains(type) else {
                throw MochletError.message("This Drive type is not supported for text analysis. Download it explicitly and use Files for local analysis.")
            }
            contentRequest = request(host: "www.googleapis.com", path: path, query: ["alt": "media", "supportsAllDrives": "true"])
        }
        let data = try await http.send(contentRequest)
        guard data.count <= 1_000_000, let body = String(data: data, encoding: .utf8) else { throw MochletError.message("Drive text must be UTF-8 and at most 1 MB.") }
        let current = try await get("www.googleapis.com", path, fields)
        guard current["modifiedTime"] == metadata["modifiedTime"], current["trashed"] != .bool(true), current["capabilities"]["canDownload"] == .bool(true) else {
            throw MochletError.message("The Drive file changed while being read. Read it again.")
        }
        var source = ConnectedSource(accountID: account.id, service: "drive", collection: "files", remoteID: id,
            title: metadata["name"].string ?? "Drive file", body: body, url: metadata["webViewLink"].string ?? "https://drive.google.com/file/d/" + id,
            revision: metadata["modifiedTime"].string ?? "")
        source.warnings = warnings; return source
    }
    public func event(calendarID: String, id: String) async throws -> ConnectedSource {
        try await verify(scope: GoogleScope.calendar)
        let row = try await get("www.googleapis.com", ["calendar", "v3", "calendars", calendarID, "events", id])
        guard row["id"].string == id, row["status"].string != "cancelled" else { throw MochletError.message("This event is no longer available.") }
        return try calendarSource(row, calendarID: calendarID)
    }
    func calendarSource(_ row: JSONValue, calendarID: String) throws -> ConnectedSource {
        guard let id = row["id"].string, !id.isEmpty else { throw MochletError.message("Calendar event identity is missing.") }
        let fields = ["summary", "description", "location", "start", "end", "recurrence", "recurringEventId", "originalStartTime", "status", "transparency"]
        var source = ConnectedSource(accountID: account.id, service: "calendar", collection: calendarID, remoteID: id,
            title: row["summary"].string ?? "Busy or private event",
            body: JSONValue.object(Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0]) })).formatted,
            url: row["htmlLink"].string ?? "https://calendar.google.com/", revision: row["etag"].string ?? "")
        if row["start"]["date"].string != nil { source.warnings.append("All-day event. The end date is exclusive in the calendar's timezone.") }
        if !row["recurrence"].array.isEmpty { source.warnings.append("Recurring series definition. Exceptions and cancelled occurrences require an agenda lookup; this record is not an availability calculation.") }
        return source
    }

}
