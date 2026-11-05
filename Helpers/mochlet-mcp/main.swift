// mochlet-mcp: the MCP stdio transport for coding agents. Each newline-delimited JSON-RPC
// message on stdin is POSTed to the running Mochlet app's local endpoint and the reply is
// written to stdout. Foundation only, so it starts instantly.
//
//   claude mcp add mochlet -- "~/Library/Application Support/Mochlet/bin/mochlet-mcp"
import Foundation

struct Endpoint: Decodable {
    var port: Int
    var token: String
    var pid: Int
}

let supportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mochlet")
let endpointURL = supportDir.appendingPathComponent("mcp.json")
let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 180
    return URLSession(configuration: c)
}()

func endpoint() -> Endpoint? {
    guard let data = try? Data(contentsOf: endpointURL), let e = try? JSONDecoder().decode(Endpoint.self, from: data) else { return nil }
    return kill(pid_t(e.pid), 0) == 0 || errno == EPERM ? e : nil
}

func post(_ body: Data, to e: Endpoint) -> (status: Int, body: Data)? {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(e.port)/mcp")!)
    r.httpMethod = "POST"
    r.httpBody = body
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    r.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: (Int, Data)?
    session.dataTask(with: r) { data, resp, _ in
        if let http = resp as? HTTPURLResponse { out = (http.statusCode, data ?? Data()) }
        sem.signal()
    }.resume()
    sem.wait()
    return out
}

func write(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func errorReply(id: Any, _ message: String) {
    let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
    if let d = try? JSONSerialization.data(withJSONObject: obj) { write(d) }
}

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IONBF, 0)

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    let data = Data(trimmed.utf8)
    let parsed = try? JSONSerialization.jsonObject(with: data)
    let id: Any? = (parsed as? [String: Any])?["id"]
    guard let e = endpoint() else {
        if let id { errorReply(id: id, "Mochlet is not running. Open Mochlet.app, then try again.") }
        continue
    }
    guard let (status, body) = post(data, to: e) else {
        if let id { errorReply(id: id, "Mochlet did not answer on port \(e.port).") }
        continue
    }
    switch status {
    case 200 where !body.isEmpty:
        // One line per message: re-serialise compactly in case the server pretty-printed.
        if let obj = try? JSONSerialization.jsonObject(with: body), let compact = try? JSONSerialization.data(withJSONObject: obj) { write(compact) } else { write(body) }
    case 202, 204:
        break
    default:
        if let id { errorReply(id: id, "Mochlet answered HTTP \(status).") }
    }
}
