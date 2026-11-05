import Foundation
import MochletCore
import MochletServices

enum LLMError: Error, CustomStringConvertible {
    case noBrain(String)
    case failed(String)
    case badJSON(String)
    case timeout
    var description: String {
        switch self {
        case .noBrain(let s): return "No brain configured: \(s)"
        case .failed(let s): return s
        case .badJSON(let s): return "The model did not return valid JSON: \(s)"
        case .timeout: return "The model took too long."
        }
    }
}

/// Error text that reads well for our own `CustomStringConvertible` errors and for Foundation's.
enum ErrorText {
    static func describe(_ e: Error) -> String {
        if let l = e as? LocalizedError, let d = l.errorDescription { return d }
        if let c = e as? CustomStringConvertible { return c.description }
        return e.localizedDescription
    }
}

/// The brain for non-chat work (reports, integration plans, typed decisions): the chat backend the
/// user picked, used one-shot. Structured output goes through Claude Code's `--json-schema` when the
/// CLI advertises it; every other backend gets the schema in the prompt and a repair pass.
struct LLMClient: Sendable {
    let kind: ChatProviderKind
    let model: String
    let provider: any ChatProvider

    @MainActor
    static func brain(_ app: AppCoordinator) -> LLMClient? {
        let kind = app.chat.providerKind
        guard let p = app.chat.makeProvider(kind) else { return nil }
        (p as? CLIChatProvider)?.lean = true
        let model = kind.isCLI ? app.chat.model : (app.chat.model.isEmpty ? (kind.defaultModels.first ?? "") : app.chat.model)
        return LLMClient(kind: kind, model: model, provider: p)
    }

    /// Recorded in `generated.by` of every page the brain wrote.
    var label: String { model.isEmpty ? kind.displayName : "\(kind.displayName) \(model)" }
    var canSeeImages: Bool { kind.supportsImages || kind == .claudeCLI }

    func complete(system: String?, user: String, attachments: [ChatAttachment] = [], cwd: String? = nil, maxTokens: Int = 4096, timeout: Double = 240) async throws -> String {
        let request = ChatRequest(messages: [ChatMessage(threadID: "brain", role: .user, text: user, attachments: attachments)], system: system, model: model, maxTokens: maxTokens, cwd: cwd)
        let provider = self.provider
        return try await withTimeout(timeout) {
            var text = ""
            var failure: String?
            for try await ev in provider.stream(request) {
                try Task.checkCancellation()
                switch ev {
                case .textDelta(let t): text += t
                case .failed(let m): failure = m
                default: break
                }
            }
            if let failure, text.isEmpty { throw LLMError.failed(failure) }
            return text
        }
    }

    func structured<T: Decodable & Sendable>(_ type: T.Type, system: String, user: String, schema: JSONValue, maxTokens: Int = 8000) async throws -> T {
        if kind == .claudeCLI, let text = try await claudeStructured(system: system, user: user, schema: schema) {
            if let v = JSONRepair.decode(T.self, from: text) { return v }
        }
        let sys = system + "\n\nReply with exactly one JSON object and nothing else: no code fences, no prose before or after. It must match this JSON Schema:\n" + String(decoding: schema.data(), as: UTF8.self)
        let text = try await complete(system: sys, user: user, maxTokens: maxTokens)
        if let v = JSONRepair.decode(T.self, from: text) { return v }
        let fixed = try await complete(system: sys, user: "The reply below is not valid JSON for the schema. Return the corrected JSON object only.\n\n" + String(text.prefix(8000)), maxTokens: maxTokens)
        if let v = JSONRepair.decode(T.self, from: fixed) { return v }
        throw LLMError.badJSON(OneLine.collapse(text, limit: 160))
    }

    /// `claude -p --output-format json --json-schema …` validates the shape on its side and returns it as `structured_output`.
    private func claudeStructured(system: String, user: String, schema: JSONValue) async throws -> String? {
        guard let bin = CLIBinaries.find("claude") else { return nil }
        let caps = CLIBinaries.capabilities(bin)
        guard caps.has("--json-schema") else { return nil }
        var args = ["-p", "--output-format", "json", "--json-schema", String(decoding: schema.data(), as: UTF8.self)] + CLIArgs.claudeLeanFlags(caps)
        if !model.isEmpty { args += ["--model", model] }
        let systemViaFlag = caps.has("--append-system-prompt")
        if systemViaFlag { args += ["--append-system-prompt", system] }
        let process = CLIProcess(binary: bin, args: args, cwd: nil, env: CLIBinaries.environment(extra: ["MOCHLET_BRAIN": "1"]))
        let lines = try process.run(stdinText: systemViaFlag ? user : "<instructions>\n\(system)\n</instructions>\n\n" + user)
        return try await withTimeout(300, onTimeout: { process.terminate() }) {
            var last: JSONValue?
            for await line in lines {
                if let v = JSONValue.parse(line), v["type"].string == "result" { last = v }
            }
            guard let last else {
                let err = process.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !err.isEmpty { throw LLMError.failed(OneLine.collapse(err, limit: 200)) }
                return nil
            }
            if last["is_error"].bool == true { throw LLMError.failed(OneLine.collapse(last["result"].string ?? "claude failed", limit: 200)) }
            if last["structured_output"].object != nil { return String(decoding: last["structured_output"].data(), as: UTF8.self) }
            return last["result"].string
        }
    }

    /// A description of an image: attached to vision-capable APIs, read by Claude Code through its Read tool.
    func describeImage(at url: URL) async throws -> String? {
        if kind.supportsImages, let png = ImageExtractor.pngForModel(url) {
            let a = ChatAttachment(kind: .image, title: url.lastPathComponent, text: "", imageBase64: png.base64EncodedString())
            return try await complete(system: nil, user: ReportPrompts.describeImage, attachments: [a], maxTokens: 1200, timeout: 120)
        }
        if kind == .claudeCLI {
            return try await complete(system: nil, user: "Use the Read tool to look at the image file \(url.path), then: " + ReportPrompts.describeImage,
                                      cwd: url.deletingLastPathComponent().path, maxTokens: 1200, timeout: 180)
        }
        return nil
    }
}

/// Runs `body` or throws `LLMError.timeout`, calling `onTimeout` (to kill a process) first.
func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: (@Sendable () -> Void)? = nil, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            onTimeout?()
            throw LLMError.timeout
        }
        guard let first = try await group.next() else { throw LLMError.timeout }
        group.cancelAll()
        return first
    }
}

/// Typed decisions through the brain: the question, the options and a JSON answer.
struct LLMJSONDecisionEngine: DecisionEngine {
    let name: String
    let client: LLMClient

    init(client: LLMClient) {
        self.client = client
        name = "llm-json:" + client.kind.rawValue
    }

    func decide(_ r: DecisionRequest) async throws -> DecisionAnswer {
        let text = try await client.complete(system: "You make one quick typed decision for a personal assistant. Answer with the JSON object only.",
                                             user: DecisionPrompt.text(r), maxTokens: 200, timeout: 120)
        return try DecisionPrompt.parse(text, options: r.options, backend: name)
    }
}
