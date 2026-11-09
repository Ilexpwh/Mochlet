import Foundation

public enum ChatRole: String, Codable, Sendable, Equatable {
    case user, assistant, system
}

/// Context attached to a message: a window, a file, pasted text, an image.
public struct ChatAttachment: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case window, file, text, image, knowledge }
    public var id: String
    public var kind: Kind
    public var title: String
    public var text: String
    public var path: String?
    /// PNG, base64, only for `.image` / window captures.
    public var imageBase64: String?

    public init(id: String = UUID().uuidString, kind: Kind, title: String, text: String, path: String? = nil, imageBase64: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.path = path
        self.imageBase64 = imageBase64
    }

    /// How the attachment is spliced into the prompt for providers without native attachments.
    public var promptBlock: String {
        var head = "<attachment kind=\"\(kind.rawValue)\" title=\"\(title.replacingOccurrences(of: "\"", with: "'"))\""
        if let path { head += " path=\"\(path)\"" }
        head += ">"
        return head + "\n" + text + "\n</attachment>"
    }
}

public struct ChatUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var threadID: String
    public var role: ChatRole
    public var text: String
    public var attachments: [ChatAttachment]
    /// Tool activity lines shown under an assistant reply ("Reads · x").
    public var activity: [String]
    public var error: String?
    public var usage: ChatUsage?
    public var createdAt: Date

    public init(id: String = UUID().uuidString, threadID: String, role: ChatRole, text: String, attachments: [ChatAttachment] = [],
                activity: [String] = [], error: String? = nil, usage: ChatUsage? = nil, createdAt: Date = Date()) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.text = text
        self.attachments = attachments
        self.activity = activity
        self.error = error
        self.usage = usage
        self.createdAt = createdAt
    }
}

public struct ChatThread: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var provider: String
    public var model: String
    /// Claude session id / Codex thread id / Gemini session id, so the CLI continues the same conversation.
    public var continuation: String?
    public var projectSlug: String?
    public var cwd: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, title: String = "New chat", provider: String, model: String, continuation: String? = nil,
                projectSlug: String? = nil, cwd: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.provider = provider
        self.model = model
        self.continuation = continuation
        self.projectSlug = projectSlug
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What a provider streams back.
public enum ChatEvent: Sendable, Equatable {
    case started(continuation: String?)
    case textDelta(String)
    case activity(String)
    case usage(ChatUsage)
    case done
    case failed(String)
}

public struct ChatRequest: Sendable, Equatable {
    public var messages: [ChatMessage]
    public var system: String?
    public var model: String
    public var maxTokens: Int
    public var continuation: String?
    public var cwd: String?

    public init(messages: [ChatMessage], system: String? = nil, model: String, maxTokens: Int = 4096, continuation: String? = nil, cwd: String? = nil) {
        self.messages = messages
        self.system = system
        self.model = model
        self.maxTokens = maxTokens
        self.continuation = continuation
        self.cwd = cwd
    }

    /// Only the turns after the continuation point are sent to a CLI that remembers the thread.
    public var lastUserMessage: ChatMessage? { messages.last { $0.role == .user } }
}

public enum ChatAPIStyle: Sendable, Equatable {
    case anthropic, openAI, cli
}

/// Every chat backend the app knows, with its wire style, endpoint and defaults.
public enum ChatProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCLI = "claude-cli"
    case codexCLI = "codex-cli"
    case geminiCLI = "gemini-cli"
    case anthropic
    case openrouter
    case openai
    case deepseek
    case qwen
    case moonshot
    case google
    case ollama
    case lmstudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCLI: return "Claude Code"
        case .codexCLI: return "Codex"
        case .geminiCLI: return "Gemini CLI"
        case .anthropic: return "Anthropic API"
        case .openrouter: return "OpenRouter"
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .qwen: return "Qwen"
        case .moonshot: return "Moonshot"
        case .google: return "Google AI"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        }
    }

    public var glyph: String {
        switch self {
        case .claudeCLI, .anthropic: return "✳"
        case .codexCLI, .openai: return "◎"
        case .geminiCLI, .google: return "✦"
        case .openrouter: return "⇄"
        case .deepseek: return "◇"
        case .qwen: return "Q"
        case .moonshot: return "☾"
        case .ollama: return "🦙"
        case .lmstudio: return "▣"
        }
    }

    public var style: ChatAPIStyle {
        switch self {
        case .claudeCLI, .codexCLI, .geminiCLI: return .cli
        case .anthropic: return .anthropic
        default: return .openAI
        }
    }

    public var isCLI: Bool { style == .cli }

    /// Local servers and CLIs need no key.
    public var needsKey: Bool {
        switch self {
        case .claudeCLI, .codexCLI, .geminiCLI, .ollama, .lmstudio: return false
        default: return true
        }
    }

    public var defaultBaseURL: String? {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .claudeCLI, .codexCLI, .geminiCLI: return nil
        }
    }

    public var defaultModels: [String] {
        switch self {
        case .claudeCLI: return ["", "sonnet", "opus", "haiku"]
        case .codexCLI: return ["", "gpt-5.5-codex", "gpt-5.5"]
        case .geminiCLI: return ["", "gemini-3.1-pro", "gemini-3.1-flash"]
        case .anthropic: return ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
        case .openrouter: return ["anthropic/claude-sonnet-5.5", "openai/gpt-5.5", "google/gemini-3.1-pro", "deepseek/deepseek-v4"]
        case .openai: return ["gpt-5.5", "gpt-5.5-mini"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .qwen: return ["qwen-max", "qwen-plus", "qwen-turbo"]
        case .moonshot: return ["kimi-k3", "moonshot-v1-128k"]
        case .google: return ["gemini-3.1-pro", "gemini-3.1-flash"]
        case .ollama: return []
        case .lmstudio: return []
        }
    }

    /// Keychain account name for the API key.
    public var keychainAccount: String { "\(rawValue)-api-key" }

    public var supportsImages: Bool {
        switch self {
        case .anthropic, .openrouter, .openai, .google, .qwen, .moonshot: return true
        default: return false
        }
    }

    /// `stream_options.include_usage` is understood by these OpenAI-style servers.
    public var sendsStreamUsage: Bool {
        switch self {
        case .openai, .openrouter, .deepseek, .qwen, .moonshot: return true
        default: return false
        }
    }

    public var agentKind: AgentKind? {
        switch self {
        case .claudeCLI: return .claude
        case .codexCLI: return .codex
        case .geminiCLI: return .gemini
        default: return nil
        }
    }
}
