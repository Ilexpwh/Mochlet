import Foundation

/// What a tool call returns to the MCP client.
public struct MCPToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    public var structured: JSONValue?
    public init(text: String, isError: Bool = false, structured: JSONValue? = nil) {
        self.text = text
        self.isError = isError
        self.structured = structured
    }
    public static func error(_ message: String) -> MCPToolResult { MCPToolResult(text: message, isError: true) }
}

/// The app implements the tools; the handler only speaks JSON-RPC.
public protocol MCPBackend: Sendable {
    func call(tool: String, arguments: JSONValue) async -> MCPToolResult
}

public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPTools {
    static func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }
    static func str(_ d: String) -> JSONValue { .object(["type": .string("string"), "description": .string(d)]) }
    static func int(_ d: String) -> JSONValue { .object(["type": .string("integer"), "description": .string(d)]) }

    public static let catalogue: [MCPTool] = [
        MCPTool(name: "find", description: "Fast lexical + vector lookup over the knowledge base (no LLM). Returns the best passages with page paths and line ranges.",
                inputSchema: schema(["query": str("Words or a phrase."), "k": int("How many passages (default 8)."), "type": str("Only pages of this type (report, entity, concept, synthesis, meeting, note, digest)."), "project": str("Prefer pages filed to this project slug.")], required: ["query"])),
        MCPTool(name: "search", description: "Answer a question from the knowledge base with [n] citations (uses the configured model).",
                inputSchema: schema(["question": str("The question, in any language."), "k": int("Passages to consider (default 8).")], required: ["question"])),
        MCPTool(name: "read", description: "Read a page or a mirrored reference by its path relative to the knowledge base root.",
                inputSchema: schema(["path": str("Relative path, e.g. inbox/some-report.md or concepts/x.md"), "lines": str("Optional line range like 40-80.")], required: ["path"])),
        MCPTool(name: "list", description: "List the pages in a folder with their titles and descriptions (reads index.md).",
                inputSchema: schema(["path": str("Folder relative to the root; empty for the root.")])),
        MCPTool(name: "tree", description: "The folder tree of the knowledge base with page counts.",
                inputSchema: schema(["depth": int("Maximum depth (default 3).")])),
        MCPTool(name: "grep", description: "Literal substring search over every page.",
                inputSchema: schema(["pattern": str("Text to look for."), "path": str("Restrict to this folder."), "limit": int("Maximum hits (default 50).")], required: ["pattern"])),
        MCPTool(name: "add_resource", description: "File a URL, a local file path or a piece of text into the knowledge base exactly like dropping it on Mochlet.",
                inputSchema: schema(["url": str("A web page, PDF or repository URL."), "path": str("A local file path."), "text": str("Raw text to file."), "title": str("Title for text."), "project": str("Project slug to file under.")])),
        MCPTool(name: "projects", description: "The registered projects (slug, name, path, description).", inputSchema: schema([:])),
        MCPTool(name: "signals_latest", description: "The latest AI-signals digest (title, hot items, path).", inputSchema: schema(["count": int("Items to include (default 10).")])),
    ]
}

/// JSON-RPC 2.0 over the Streamable HTTP transport (one request → one response; notifications → nil).
public struct MCPHandler: Sendable {
    public static let protocolVersion = "2025-06-18"
    public var serverName = "mochlet"
    public var serverVersion = "2.0"
    public var instructions = "Mochlet's personal knowledge base. Read the root index with `list` first; use `find` for quick lookups, `search` for cited answers, `add_resource` to file something."
    let backend: MCPBackend

    public init(backend: MCPBackend) { self.backend = backend }

    /// Handles one message or a batch; returns nil when nothing should be sent back.
    public func handle(_ message: JSONValue) async -> JSONValue? {
        if let batch = message.array {
            var out: [JSONValue] = []
            for m in batch { if let r = await handleOne(m) { out.append(r) } }
            return out.isEmpty ? nil : .array(out)
        }
        return await handleOne(message)
    }

    func handleOne(_ m: JSONValue) async -> JSONValue? {
        let id = m["id"]
        let method = m["method"].string ?? ""
        let params = m["params"]
        if id.isNull {
            // Notifications never get a response.
            return nil
        }
        switch method {
        case "initialize":
            return response(id, .object([
                "protocolVersion": .string(params["protocolVersion"].string ?? Self.protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(serverName), "version": .string(serverVersion)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return response(id, .object([:]))
        case "tools/list":
            return response(id, .object(["tools": .array(MCPTools.catalogue.map {
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema])
            })]))
        case "tools/call":
            guard let name = params["name"].string else { return error(id, -32602, "missing tool name") }
            guard MCPTools.catalogue.contains(where: { $0.name == name }) else { return error(id, -32602, "unknown tool \(name)") }
            let result = await backend.call(tool: name, arguments: params["arguments"])
            var o: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(result.text)])]), "isError": .bool(result.isError)]
            if let s = result.structured { o["structuredContent"] = s }
            return response(id, .object(o))
        case "resources/list", "prompts/list":
            return response(id, .object([method.hasPrefix("resources") ? "resources" : "prompts": .array([])]))
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    func response(_ id: JSONValue, _ result: JSONValue) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "result": result]) }
    func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}

/// The stdio side used by `mochlet-mcp`: Claude Code / Codex speak newline-delimited JSON-RPC on
/// stdin/stdout; each line is forwarded to the app's HTTP endpoint.
public enum MCPEndpointFile {
    /// `~/Library/Application Support/Mochlet/mcp.json`: where the app listens and the bearer token.
    public struct Info: Codable, Equatable, Sendable {
        public var port: Int
        public var token: String
        public var pid: Int
        public init(port: Int, token: String, pid: Int) {
            self.port = port
            self.token = token
            self.pid = pid
        }
    }

    public static func encode(_ info: Info) -> Data { (try? JSONEncoder().encode(info)) ?? Data() }
    public static func decode(_ data: Data) -> Info? { try? JSONDecoder().decode(Info.self, from: data) }
}
