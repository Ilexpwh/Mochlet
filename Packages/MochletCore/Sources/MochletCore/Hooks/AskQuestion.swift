import Foundation

/// A parsed AskUserQuestion tool call (1–4 questions, 2–4 options each).
public struct AskQuestion: Sendable, Equatable, Codable {
    public struct Option: Sendable, Equatable, Codable {
        public var label: String
        public var description: String
        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }
    public struct Question: Sendable, Equatable, Codable {
        public var text: String
        public var header: String
        public var options: [Option]
        public var multiSelect: Bool
        public init(text: String, header: String = "", options: [Option], multiSelect: Bool = false) {
            self.text = text
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public var questions: [Question]
    /// The original `questions` array, echoed back in `updatedInput`.
    public var original: JSONValue

    public static let maxQuestions = 4
    public static let headerLimit = 12

    public static func parse(_ toolInput: JSONValue) -> AskQuestion? {
        guard let qs = toolInput["questions"].array, !qs.isEmpty, qs.count <= maxQuestions else { return nil }
        var out: [Question] = []
        for q in qs {
            guard let text = q["question"].string, !text.isEmpty, let opts = q["options"].array, (2...4).contains(opts.count) else { return nil }
            var options: [Option] = []
            for o in opts {
                guard let label = o["label"].string, !label.isEmpty else { return nil }
                options.append(Option(label: label, description: o["description"].string ?? ""))
            }
            out.append(Question(text: text, header: String((q["header"].string ?? "").prefix(headerLimit)), options: options, multiSelect: q["multiSelect"].bool ?? false))
        }
        return AskQuestion(questions: out, original: toolInput["questions"])
    }

    public var hasDescriptions: Bool { questions.contains { $0.options.contains { !$0.description.isEmpty } } }

    /// `answers` object keyed by question text: a string for single-select, an array for multi-select.
    /// Unanswered questions are left out.
    public func answers(selections: [[String]]) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (i, q) in questions.enumerated() where i < selections.count {
            let picks = selections[i]
            guard !picks.isEmpty else { continue }
            o[q.text] = q.multiSelect ? .array(picks.map { .string($0) }) : .string(picks[0])
        }
        return .object(o)
    }

    /// The hook output for Claude Code's PreToolUse `AskUserQuestion` matcher.
    public func hookOutput(answers: JSONValue) -> JSONValue {
        .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string("allow"),
            "updatedInput": .object(["questions": original, "answers": answers]),
        ])])
    }
}
