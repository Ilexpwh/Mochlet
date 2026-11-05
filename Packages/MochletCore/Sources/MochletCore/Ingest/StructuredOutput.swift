import Foundation

/// JSON Schema fragments (as JSONValue) for the structured outputs Mochlet asks a model for.
public enum Schemas {
    public static func object(_ props: [String: JSONValue], required: [String] = [], description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(props), "additionalProperties": .bool(false)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    public static func string(_ d: String) -> JSONValue { .object(["type": .string("string"), "description": .string(d)]) }
    public static func number(_ d: String) -> JSONValue { .object(["type": .string("number"), "description": .string(d)]) }
    public static func boolean(_ d: String) -> JSONValue { .object(["type": .string("boolean"), "description": .string(d)]) }
    public static func array(_ items: JSONValue, _ d: String) -> JSONValue { .object(["type": .string("array"), "items": items, "description": .string(d)]) }
    public static func strings(_ d: String) -> JSONValue { array(.object(["type": .string("string")]), d) }

    /// `ReportDraft` (snake_case keys).
    public static let report: JSONValue = object([
        "title": string("A clear title for the source (keep the original language)."),
        "one_liner": string("One sentence: what it is and the main takeaway (≤ 140 characters)."),
        "summary": string("3–6 sentences, answer-first, in the language of the source."),
        "key_points": strings("5–10 concrete points, each one line, with numbers and names kept."),
        "why_it_matters": string("Why this matters to the reader (1–3 sentences)."),
        "entities": array(object(["name": string("Canonical name."), "kind": string("person | org | product | model | paper | place | event | concept"), "note": string("Role in this source (short).")], required: ["name", "kind"]), "People, organisations, products, models, papers mentioned."),
        "tags": strings("3–8 lowercase topic tags."),
        "language": string("BCP-47 language of the source: en, zh, ja…"),
        "content_kind": string("article | paper | repo | slides | document | transcript | meeting | thread | video | image | note | link"),
        "suggested_project": string("The slug of the best matching project from the list, or empty."),
        "project_confidence": number("0–1 confidence in suggested_project."),
        "action_items": array(object(["text": string("The action."), "owner": string("Who, if stated."), "due": string("When, if stated.")], required: ["text"]), "Explicit to-dos found in the source."),
        "open_questions": strings("Questions the source raises but does not answer."),
        "quotes": array(object(["text": string("Verbatim quote (≤ 200 characters)."), "location": string("Page, slide, timestamp or heading.")], required: ["text"]), "2–4 quotes worth keeping."),
        "related": strings("Titles of existing knowledge-base pages this source relates to (from the context list only)."),
    ], required: ["title", "one_liner", "summary", "key_points", "entities", "tags", "language", "content_kind"])

    /// `IntegrationPlan`.
    public static let integration: JSONValue = object([
        "revise": array(object(["path": string("Existing page path."), "section": string("Heading of the section to change, or empty for the whole body."), "mode": string("replace | append"), "text": string("New Markdown for the section (with [[wikilinks]])."), "reason": string("Why.")], required: ["path", "mode", "text"]), "Existing pages to revise."),
        "create": array(object(["type": string("entity | concept | comparison"), "title": string("Page title."), "body": string("Full Markdown body starting with a # heading, with [[wikilinks]] to related pages."), "description": string("One line."), "tags": strings("Tags.")], required: ["type", "title", "body"]), "New pages."),
        "links": array(object(["from": string("Page path or title."), "to": string("Page path or title.")], required: ["from", "to"]), "Extra links to add both ways."),
    ], required: ["revise", "create", "links"])

    /// A single choice among options.
    public static func choice(_ ids: [String]) -> JSONValue {
        object(["choice": .object(["type": .string("string"), "enum": .array(ids.map { .string($0) })]), "confidence": number("0–1"), "reason": string("Short reason.")], required: ["choice", "confidence"])
    }

    /// Map-reduce notes for long sources.
    public static let notes: JSONValue = object(["notes": strings("The facts, numbers, names, decisions and claims in this part, one per line, in the source language.")], required: ["notes"])
}

/// Finds the JSON object a model wrapped in prose or code fences, so one repair round-trip is rarely needed.
public enum JSONRepair {
    public static func extractObject(_ text: String) -> JSONValue? {
        if let v = JSONValue.parse(text), v.object != nil { return v }
        var s = text
        if let r = s.range(of: "```json", options: .caseInsensitive) { s = String(s[r.upperBound...]) }
        else if let r = s.range(of: "```") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "```") { s = String(s[..<r.lowerBound]) }
        if let v = JSONValue.parse(s.trimmingCharacters(in: .whitespacesAndNewlines)), v.object != nil { return v }
        guard let start = s.firstIndex(of: "{") else { return nil }
        // Walk to the matching brace, respecting strings.
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return JSONValue.parse(String(s[start...i])) } }
            i = s.index(after: i)
        }
        // Unterminated: close what is open.
        var tail = String(s[start...])
        if inString { tail += "\"" }
        tail += String(repeating: "}", count: max(0, depth))
        return JSONValue.parse(tail)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let v = extractObject(text) else { return nil }
        return try? JSONDecoder().decode(T.self, from: v.data())
    }
}
