import Foundation

/// Anthropic Messages API: request body and streaming event parser.
public enum AnthropicRequest {
    public static func body(_ r: ChatRequest, supportsImages: Bool = true) -> JSONValue {
        var messages: [JSONValue] = []
        for m in r.messages where m.role != .system {
            var blocks: [JSONValue] = []
            if m.role == .user {
                for a in m.attachments {
                    if a.kind == .image || a.imageBase64 != nil, supportsImages, let b64 = a.imageBase64 {
                        blocks.append(.object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string(b64)])]))
                    }
                    if !a.text.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(a.promptBlock)])) }
                }
            }
            if !m.text.isEmpty || blocks.isEmpty { blocks.append(.object(["type": .string("text"), "text": .string(m.text.isEmpty ? "(empty)" : m.text)])) }
            messages.append(.object(["role": .string(m.role.rawValue), "content": .array(blocks)]))
        }
        var body: [String: JSONValue] = [
            "model": .string(r.model),
            "max_tokens": .number(Double(r.maxTokens)),
            "stream": .bool(true),
            "messages": .array(messages),
        ]
        if let s = r.system, !s.isEmpty { body["system"] = .string(s) }
        return .object(body)
    }
}

public struct AnthropicStreamParser: Sendable {
    private var inputTokens = 0
    private var outputTokens = 0
    private var thinkingAnnounced = false

    public init() {}

    public mutating func parse(_ e: SSEEvent) -> [ChatEvent] {
        guard let j = JSONValue.parse(e.data) else { return [] }
        let type = e.event ?? j["type"].string ?? ""
        switch type {
        case "message_start":
            inputTokens = j["message"]["usage"]["input_tokens"].int ?? 0
            return [.started(continuation: j["message"]["id"].string)]
        case "content_block_start":
            if j["content_block"]["type"].string == "thinking", !thinkingAnnounced {
                thinkingAnnounced = true
                return [.activity("thinking")]
            }
            if j["content_block"]["type"].string == "tool_use", let name = j["content_block"]["name"].string {
                return [.activity("Uses · \(name)")]
            }
            return []
        case "content_block_delta":
            let d = j["delta"]
            if d["type"].string == "text_delta", let t = d["text"].string { return [.textDelta(t)] }
            return []
        case "message_delta":
            if let o = j["usage"]["output_tokens"].int { outputTokens = o }
            return []
        case "message_stop":
            return [.usage(ChatUsage(inputTokens: inputTokens, outputTokens: outputTokens)), .done]
        case "error":
            return [.failed(j["error"]["message"].string ?? "Anthropic error")]
        default:
            return []
        }
    }
}
