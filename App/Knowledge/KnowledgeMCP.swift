import Foundation
import MochletCore
import MochletServices

/// The loopback MCP endpoint: `POST /mcp` (bearer token, JSON-RPC 2.0, one message per request)
/// and `GET /health`. `mcp.json` in the support folder tells the `mochlet-mcp` stdio shim where it is.
final class KnowledgeMCPServer: @unchecked Sendable {
    static let endpointFile = RelayInstaller.supportDir.appendingPathComponent("mcp.json")

    let token: String
    private let server: LocalHTTPServer
    private(set) var port: UInt16 = 0

    init(backend: MCPBackend) {
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        self.token = token
        let handler = MCPHandler(backend: backend)
        server = LocalHTTPServer { req in
            switch (req.method, req.route) {
            case ("GET", "/health"):
                return .json(Data(#"{"ok":true,"server":"mochlet","version":"2.0"}"#.utf8))
            case ("POST", "/mcp"):
                guard req.headers["authorization"] == "Bearer \(token)" else { return .text("unauthorised", status: 401) }
                guard let message = JSONValue.parse(req.body) else {
                    return .json(Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#.utf8), status: 400)
                }
                if let reply = await handler.handle(message) { return .json(reply.data()) }
                return HTTPResponse(status: 202)
            case ("GET", "/mcp"), ("DELETE", "/mcp"):
                return .text("Mochlet speaks JSON-RPC over POST only (no SSE stream, no sessions).", status: 405)
            default:
                return .text("not found", status: 404)
            }
        }
    }

    func start() async throws -> UInt16 {
        port = try await server.start()
        let info = MCPEndpointFile.Info(port: Int(port), token: token, pid: Int(getpid()))
        try? FileManager.default.createDirectory(at: RelayInstaller.supportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try MCPEndpointFile.encode(info).write(to: Self.endpointFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.endpointFile.path)
        return port
    }

    func stop() {
        server.stop()
        try? FileManager.default.removeItem(at: Self.endpointFile)
    }
}

/// Tool calls run on the main actor (they read the projects registry and the chat settings) and
/// hand the heavy lifting to the knowledge engine.
struct KnowledgeMCPBackend: MCPBackend {
    func call(tool: String, arguments: JSONValue) async -> MCPToolResult {
        await AppCoordinator.shared.knowledge.mcpCall(tool: tool, arguments: arguments)
    }
}
