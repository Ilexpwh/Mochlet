import Foundation
import MochletCore

/// A chat backend: streams events for a request, lists models, can be cancelled by dropping the stream.
protocol ChatProvider: Sendable {
    var kind: ChatProviderKind { get }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func models() async throws -> [String]
}

// MARK: - HTTP providers (Anthropic Messages, OpenAI-compatible)

struct HTTPChatProvider: ChatProvider {
    let kind: ChatProviderKind
    let baseURL: String
    let apiKey: String?

    private func request(path: String, method: String = "POST", body: Data? = nil) throws -> URLRequest {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw ChatProviderError.badURL(base + path) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Mochlet", forHTTPHeaderField: "User-Agent")
        switch kind.style {
        case .anthropic:
            if let apiKey { r.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            if let apiKey, !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            if kind == .openrouter {
                r.setValue("https://github.com/Ilexpwh/Mochlet", forHTTPHeaderField: "HTTP-Referer")
                r.setValue("Mochlet", forHTTPHeaderField: "X-Title")
            }
        }
        r.httpBody = body
        return r
    }

    func stream(_ req: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let body: JSONValue = kind.style == .anthropic ? AnthropicRequest.body(req, supportsImages: kind.supportsImages) : OpenAIRequest.body(req, kind: kind)
                    let path = kind.style == .anthropic ? "/v1/messages" : "/chat/completions"
                    let r = try request(path: path, body: body.data(pretty: false, sortedKeys: false))
                    let (bytes, response) = try await URLSession.shared.bytes(for: r)
                    guard let http = response as? HTTPURLResponse else { throw ChatProviderError.badResponse }
                    if http.statusCode >= 300 {
                        var text = ""
                        for try await line in bytes.lines where text.count < 4000 { text += line }
                        let msg = JSONValue.parse(text).flatMap { $0["error"]["message"].string ?? $0["error"].string ?? $0["message"].string } ?? text
                        cont.yield(.failed("HTTP \(http.statusCode): \(OneLine.collapse(msg, limit: 300))"))
                        cont.finish()
                        return
                    }
                    var sse = SSEParser()
                    var anthropic = AnthropicStreamParser()
                    var openAI = OpenAIStreamParser()
                    var finished = false
                    func handle(_ e: SSEEvent) {
                        let events = kind.style == .anthropic ? anthropic.parse(e) : openAI.parse(e)
                        for ev in events {
                            if case .done = ev { finished = true }
                            if case .failed = ev { finished = true }
                            cont.yield(ev)
                        }
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for e in sse.feed(line + "\n") { handle(e) }
                        if finished { break }
                    }
                    for e in sse.finish() { handle(e) }
                    if !finished { cont.yield(.done) }
                    cont.finish()
                } catch is CancellationError {
                    cont.finish()
                } catch {
                    cont.yield(.failed(error.localizedDescription))
                    cont.finish()
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func models() async throws -> [String] {
        let r = try request(path: "/v1/models".replacingOccurrences(of: "/v1/v1", with: "/v1"), method: "GET")
        let (data, response) = try await URLSession.shared.data(for: fixedModelsRequest(r))
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else { throw ChatProviderError.badResponse }
        guard let j = JSONValue.parse(data) else { return [] }
        let items = j["data"].array ?? j["models"].array ?? []
        return items.compactMap { $0["id"].string ?? $0["name"].string }.sorted()
    }

    /// Anthropic lists at `/v1/models`; OpenAI-style bases already end in `/v1`, so `/models`.
    private func fixedModelsRequest(_ r: URLRequest) throws -> URLRequest {
        if kind.style == .anthropic { return r }
        return try request(path: "/models", method: "GET")
    }
}

enum ChatProviderError: LocalizedError {
    case badURL(String)
    case badResponse
    case missingBinary(String)
    case noKey(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Bad URL: \(u)"
        case .badResponse: return "Unexpected response from the provider."
        case .missingBinary(let b): return "\(b) is not installed (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and PATH)."
        case .noKey(let p): return "No API key for \(p). Add one in Settings → Chat."
        }
    }
}

// MARK: - Command-line tools

/// Finds and probes the agent CLIs without pinning versions.
enum CLIBinaries {
    static var searchDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) { dirs.append("\(nvm)/\(v)/bin") }
        }
        for p in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) where !dirs.contains(p) { dirs.append(p) }
        return dirs
    }

    static func find(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for d in searchDirs where FileManager.default.isExecutableFile(atPath: "\(d)/\(name)") { return "\(d)/\(name)" }
        return nil
    }

    static var path: String { searchDirs.joined(separator: ":") }

    /// Environment for child CLIs: a full PATH and none of the variables a parent Claude Code session leaves behind.
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE") || k.hasPrefix("MOCHLET_") { env[k] = nil }
        env["PATH"] = path
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["MOCHLET_HEADLESS"] = "1"
        for (k, v) in extra { env[k] = v }
        return env
    }

    nonisolated(unsafe) private static var capsCache: [String: (Date, CLICapabilities)] = [:]
    private static let capsLock = NSLock()

    /// `--help` flags, cached by binary modification time.
    static func capabilities(_ binary: String, helpArgs: [String] = ["--help"]) -> CLICapabilities {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: binary)[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        capsLock.lock()
        if let (m, c) = capsCache[binary], m == mtime { capsLock.unlock(); return c }
        capsLock.unlock()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = helpArgs
        p.environment = environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var text = ""
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            text = String(decoding: data, as: UTF8.self)
        } catch {
            return CLICapabilities()
        }
        let caps = CLICapabilities.parse(help: text)
        capsLock.lock()
        capsCache[binary] = (mtime, caps)
        capsLock.unlock()
        return caps
    }
}

/// A child process whose stdout is read line by line; stderr is kept for error messages.
final class CLIProcess: @unchecked Sendable {
    let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let stdin = Pipe()
    private let lock = NSLock()
    private var errText = ""
    private var outBuffer = Data()
    private var continuation: AsyncStream<String>.Continuation?

    init(binary: String, args: [String], cwd: String?, env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.environment = env
        if let cwd, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
    }

    var stderrText: String { lock.withLock { errText } }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    /// Starts the process and returns its stdout lines; the stream ends when stdout closes.
    func run(stdinText: String?) throws -> AsyncStream<String> {
        let stream = AsyncStream<String> { cont in
            lock.withLock { continuation = cont }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.withLock { self.errText += String(decoding: d, as: UTF8.self); if self.errText.count > 20_000 { self.errText = String(self.errText.suffix(20_000)) } }
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty {
                h.readabilityHandler = nil
                let tail = self.lock.withLock { () -> String in
                    let t = String(decoding: self.outBuffer, as: UTF8.self)
                    self.outBuffer = Data()
                    return t
                }
                if !tail.isEmpty { self.continuation?.yield(tail) }
                self.continuation?.finish()
                return
            }
            var lines: [String] = []
            self.lock.withLock {
                self.outBuffer.append(d)
                while let nl = self.outBuffer.firstIndex(of: 0x0A) {
                    let line = self.outBuffer.subdata(in: self.outBuffer.startIndex..<nl)
                    self.outBuffer.removeSubrange(self.outBuffer.startIndex...nl)
                    lines.append(String(decoding: line, as: UTF8.self))
                }
            }
            for l in lines { self.continuation?.yield(l) }
        }
        try process.run()
        if let stdinText {
            stdin.fileHandleForWriting.write(Data(stdinText.utf8))
        }
        try? stdin.fileHandleForWriting.close()
        return stream
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// Claude Code, Codex and Gemini CLI as chat backends (the user's subscriptions, no API key).
final class CLIChatProvider: ChatProvider, @unchecked Sendable {
    let kind: ChatProviderKind
    /// Called with Claude's `rate_limit_event` payload so the plan pill stays current.
    var onRateLimits: (@Sendable (JSONValue) -> Void)?
    /// `read-only` for chat, `workspace-write` for tasks (Codex); permission/approval modes for the others.
    var taskMode = false

    init(kind: ChatProviderKind) { self.kind = kind }

    var binaryName: String {
        switch kind {
        case .codexCLI: return "codex"
        case .geminiCLI: return "gemini"
        default: return "claude"
        }
    }

    /// The prompt text sent on stdin: attachments as blocks, then the message.
    static func promptText(_ r: ChatRequest, includeSystem: Bool) -> String {
        var parts: [String] = []
        if includeSystem, let s = r.system, !s.isEmpty { parts.append("<instructions>\n\(s)\n</instructions>") }
        if let m = r.lastUserMessage {
            for a in m.attachments where !a.text.isEmpty { parts.append(a.promptBlock) }
            parts.append(m.text)
        }
        return parts.joined(separator: "\n\n")
    }

    func arguments(for r: ChatRequest, caps: CLICapabilities, sessionID: String?) -> [String] {
        switch kind {
        case .codexCLI:
            return CLIArgs.codex(resume: r.continuation, model: r.model, cwd: r.cwd, sandbox: taskMode ? "workspace-write" : "read-only", caps: caps)
        case .geminiCLI:
            return CLIArgs.gemini(resume: r.continuation, model: r.model, approvalMode: taskMode ? "yolo" : nil, caps: caps)
        default:
            var a = CLIArgs.claude(resume: r.continuation, sessionID: sessionID, model: r.model, caps: caps, permissionMode: taskMode ? "acceptEdits" : nil)
            if r.continuation == nil, let s = r.system, !s.isEmpty, caps.isEmpty || caps.has("--append-system-prompt") { a += ["--append-system-prompt", s] }
            return a
        }
    }

    func stream(_ r: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        stream(r, sessionID: nil)
    }

    func stream(_ r: ChatRequest, sessionID: String?) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let process: CLIProcess
            do {
                guard let bin = CLIBinaries.find(binaryName) else { throw ChatProviderError.missingBinary(binaryName) }
                let caps = CLIBinaries.capabilities(bin, helpArgs: kind == .codexCLI ? ["exec", "--help"] : ["--help"])
                let args = arguments(for: r, caps: caps, sessionID: sessionID)
                process = CLIProcess(binary: bin, args: args, cwd: r.cwd, env: CLIBinaries.environment())
            } catch {
                cont.yield(.failed(error.localizedDescription))
                cont.finish()
                return
            }
            let kind = self.kind
            let onRateLimits = self.onRateLimits
            let includeSystem = kind != .claudeCLI && r.continuation == nil
            let prompt = Self.promptText(r, includeSystem: includeSystem)
            let task = Task {
                var claude = ClaudeStreamParser()
                var codex = CodexExecParser()
                var gemini = GeminiStreamParser()
                var finished = false
                var sawText = false
                do {
                    let lines = try process.run(stdinText: prompt)
                    for await line in lines {
                        if Task.isCancelled { break }
                        let events: [ChatEvent]
                        switch kind {
                        case .codexCLI: events = codex.parse(line: line)
                        case .geminiCLI: events = gemini.parse(line: line)
                        default: events = claude.parse(line: line)
                        }
                        for ev in events {
                            if case .textDelta = ev { sawText = true }
                            if case .done = ev { finished = true }
                            if case .failed = ev { finished = true }
                            cont.yield(ev)
                        }
                    }
                    process.process.waitUntilExit()
                    if let rl = claude.lastRateLimits { onRateLimits?(rl) }
                    if !finished {
                        let err = OneLine.firstParagraph(process.stderrText.trimmingCharacters(in: .whitespacesAndNewlines), max: 300)
                        if process.terminationStatus != 0 || !sawText {
                            cont.yield(.failed(err.isEmpty ? "\(kind.displayName) exited (\(process.terminationStatus)) without a reply. Its output format may have changed." : err))
                        } else {
                            cont.yield(.done)
                        }
                    }
                } catch {
                    cont.yield(.failed(error.localizedDescription))
                }
                cont.finish()
            }
            cont.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
        }
    }

    func models() async throws -> [String] { kind.defaultModels }
}
