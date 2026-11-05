import Foundation

/// OpenAI-compatible chat completions: request body and streaming chunk parser.
public enum OpenAIRequest {
    public static func body(_ r: ChatRequest, kind: ChatProviderKind) -> JSONValue {
        var messages: [JSONValue] = []
        if let s = r.system, !s.isEmpty { messages.append(.object(["role": .string("system"), "content": .string(s)])) }
        for m in r.messages {
            if m.role == .user, kind.supportsImages, m.attachments.contains(where: { $0.imageBase64 != nil }) {
                var parts: [JSONValue] = []
                for a in m.attachments {
                    if let b64 = a.imageBase64 {
                        parts.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/png;base64,\(b64)")])]))
                    }
                    if !a.text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(a.promptBlock)])) }
                }
                parts.append(.object(["type": .string("text"), "text": .string(m.text)]))
                messages.append(.object(["role": .string("user"), "content": .array(parts)]))
            } else {
                var text = m.text
                if m.role == .user, !m.attachments.isEmpty {
                    text = m.attachments.map(\.promptBlock).joined(separator: "\n\n") + "\n\n" + text
                }
                messages.append(.object(["role": .string(m.role.rawValue), "content": .string(text)]))
            }
        }
        var body: [String: JSONValue] = [
            "model": .string(r.model),
            "stream": .bool(true),
            "messages": .array(messages),
        ]
        if kind.sendsStreamUsage { body["stream_options"] = .object(["include_usage": .bool(true)]) }
        if kind != .ollama, kind != .lmstudio { body["max_tokens"] = .number(Double(r.maxTokens)) }
        return .object(body)
    }
}

/// Removes `<think>…</think>` blocks across chunk boundaries (DeepSeek, Qwen, local models).
public struct ThinkStripper: Sendable {
    private var inside = false
    private var pending = ""
    private(set) public var sawThinking = false

    public init() {}

    public mutating func feed(_ s: String) -> String {
        var text = pending + s
        pending = ""
        var out = ""
        while !text.isEmpty {
            if inside {
                if let r = text.range(of: "</think>") {
                    text = String(text[r.upperBound...])
                    inside = false
                    if text.hasPrefix("\n") { text.removeFirst() }
                } else {
                    // Keep a tail in case the closing tag is split across chunks.
                    pending = String(text.suffix(7))
                    return out
                }
            } else if let r = text.range(of: "<think>") {
                out += text[..<r.lowerBound]
                text = String(text[r.upperBound...])
                inside = true
                sawThinking = true
            } else {
                // A partial "<think" at the very end waits for the next chunk.
                if let lt = text.lastIndex(of: "<"), text.distance(from: lt, to: text.endIndex) < 7, "<think>".hasPrefix(String(text[lt...])) {
                    out += text[..<lt]
                    pending = String(text[lt...])
                } else {
                    out += text
                }
                text = ""
            }
        }
        return out
    }

    public mutating func finish() -> String {
        let p = inside ? "" : pending
        pending = ""
        return p
    }
}

public struct OpenAIStreamParser: Sendable {
    private var stripper = ThinkStripper()
    private var reasoningAnnounced = false
    private var usage: ChatUsage?
    private var finished = false

    public init() {}

    public mutating func parse(_ e: SSEEvent) -> [ChatEvent] {
        let data = e.data.trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" {
            var out: [ChatEvent] = []
            let tail = stripper.finish()
            if !tail.isEmpty { out.append(.textDelta(tail)) }
            if let usage { out.append(.usage(usage)) }
            if !finished { finished = true; out.append(.done) }
            return out
        }
        guard let j = JSONValue.parse(data) else { return [] }
        if !j["error"].isNull {
            return [.failed(j["error"]["message"].string ?? j["error"].string ?? "provider error")]
        }
        var out: [ChatEvent] = []
        if let u = j["usage"].object, let i = u["prompt_tokens"]?.int, let o = u["completion_tokens"]?.int {
            usage = ChatUsage(inputTokens: i, outputTokens: o)
        }
        if let choice = j["choices"].array?.first {
            let delta = choice["delta"]
            if let reasoning = delta.firstString(["reasoning_content", "reasoning"]), !reasoning.isEmpty, !reasoningAnnounced {
                reasoningAnnounced = true
                out.append(.activity("thinking"))
            }
            if let content = delta["content"].string, !content.isEmpty {
                let t = stripper.feed(content)
                if !t.isEmpty { out.append(.textDelta(t)) }
            }
            if let calls = delta["tool_calls"].array {
                for c in calls { if let name = c["function"]["name"].string { out.append(.activity("Uses · \(name)")) } }
            }
            if let reason = choice["finish_reason"].string, !reason.isEmpty, !finished {
                let tail = stripper.finish()
                if !tail.isEmpty { out.append(.textDelta(tail)) }
                if usage == nil || !usedStreamUsage(j) {
                    // Some servers put usage on the final chunk itself.
                    if let u = j["usage"].object, let i = u["prompt_tokens"]?.int, let o = u["completion_tokens"]?.int { out.append(.usage(ChatUsage(inputTokens: i, outputTokens: o))) }
                }
                finished = true
                out.append(.done)
            }
        }
        return out
    }

    private func usedStreamUsage(_ j: JSONValue) -> Bool { j["choices"].array?.isEmpty ?? true }
}
