import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data
    public var query: [String: String] {
        guard let q = path.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
        }
        return out
    }
    public var route: String { String(path.split(separator: "?", maxSplits: 1).first ?? "") }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
    public static func json(_ data: Data, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data) }
    public static func text(_ s: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8)) }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        var h = headers
        h["Content-Length"] = String(body.count)
        h["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// A loopback-only HTTP/1.1 server on an ephemeral port (Network.framework). One request per
/// connection; bodies up to 4 MB. Used for the MCP endpoint and the signals push API.
public final class LocalHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private let handler: Handler
    private let queue = DispatchQueue(label: "mochlet.http", qos: .utility)
    public private(set) var port: UInt16 = 0
    public static let maxBody = 4 * 1024 * 1024

    public init(handler: @escaping Handler) { self.handler = handler }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start(port requested: UInt16 = 0) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requested) ?? .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { cont in
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    let p = l.port?.rawValue ?? 0
                    self?.port = p
                    cont.resume(returning: p)
                case .failed(let e):
                    guard gate.claim() else { return }
                    cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        var buffer = Data()
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer += data }
                if buffer.count > Self.maxBody + 64 * 1024 {
                    c.send(content: HTTPResponse.text("too large", status: 413).serialized, completion: .contentProcessed { _ in c.cancel() })
                    return
                }
                if let req = Self.parse(buffer) {
                    Task {
                        let resp = await self.handler(req)
                        c.send(content: resp.serialized, completion: .contentProcessed { _ in c.cancel() })
                    }
                    return
                }
                if isComplete || error != nil { c.cancel(); return }
                receive()
            }
        }
        receive()
    }

    /// Returns the request once the head and the full body have arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[String(l[..<colon]).lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body))
    }
}

/// Resumes a continuation exactly once from a callback that may fire several times.
final class ResumeGate: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
