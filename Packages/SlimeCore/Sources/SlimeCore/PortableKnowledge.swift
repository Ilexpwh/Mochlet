import Foundation
import Yams

/// Bounded YAML/Markdown envelope. Unknown metadata survives semantic round trips;
/// YAML formatting and comments may normalize when an owned field is changed.
public struct PortableKnowledge: Sendable {
    public let header: String
    public let body: String
    private let strings: [String: String]
    private let scalars: [String: String]
    private let keys: Set<String>

    public init(_ markdown: String) throws {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.utf8.count <= 2_000_000, text.hasPrefix("---\n"),
              let boundary = text.range(of: "\n---\n"), boundary.lowerBound >= text.index(text.startIndex, offsetBy: 4) else {
            throw MochletError.message("Expected Markdown with YAML frontmatter, up to 2 MB.")
        }
        header = String(text[text.index(text.startIndex, offsetBy: 4)..<boundary.lowerBound])
        body = String(text[boundary.upperBound...]).trimmingCharacters(in: .newlines)
        let node = try Self.parse(header)
        var strings: [String: String] = [:], scalars: [String: String] = [:]
        var keys = Set<String>()
        for pair in node.mapping! {
            guard let key = pair.key.scalar?.string, pair.key.tag == Tag(.str), keys.insert(key).inserted else {
                throw MochletError.message("Frontmatter requires unique string keys.")
            }
            if let value = pair.value.scalar?.string {
                scalars[key] = value
                if pair.value.tag == Tag(.str) { strings[key] = value }
            }
        }
        self.strings = strings; self.scalars = scalars; self.keys = keys
    }

    private static func parse(_ header: String) throws -> Node {
        // Bound work before invoking a recursive YAML parser. Aliases/merge keys
        // are outside this importer so expansion cannot amplify a small document.
        guard header.utf8.count <= 32_768, header.components(separatedBy: "\n").count <= 512,
              header.filter({ "[]{}".contains($0) }).count <= 256,
              header.range(of: #"(^|[\s\[\]{},:])[&*][^\s]+|(^|\n)\s*<<\s*:"#, options: .regularExpression) == nil,
              header.components(separatedBy: "\n").allSatisfy({ $0.prefix(while: { $0 == " " }).count <= 64 }),
              let node = try Yams.compose(yaml: header), node.mapping != nil else {
            throw MochletError.message("Use a YAML mapping within 32 KiB/512 lines, without aliases, merge keys or deeply nested collections.")
        }
        return node
    }

    public func contains(_ key: String) -> Bool { keys.contains(key) }
    public func scalar(_ key: String) -> String? { strings[key] }
    public var hasConceptType: Bool { !(scalar("type")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// Unknown lifecycle values are retained for review, but cannot become evidence.
    public func exclusionReason(at date: Date = Date()) -> String? {
        if keys.contains("status") {
            guard let status = scalar("status"), ["draft", "stable", "deprecated"].contains(status) else { return "Unrecognized lifecycle status" }
            if status == "draft" { return "Draft · review before using as memory" }
            if status == "deprecated" { return "Deprecated · excluded from AI context" }
        }
        if keys.contains("stale_after") {
            guard let raw = scalars["stale_after"], raw.range(of: #"(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return "Invalid freshness date" }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiry = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            guard let expiry else { return "Invalid freshness date" }
            if expiry <= date { return "Stale · review the source before using as memory" }
        }
        return nil
    }

    public func replacing(_ fields: [String: String], body: String? = nil, removing: Set<String> = []) throws -> String {
        let original = try Self.parse(header)
        var node = Node(original.mapping!.filter { !removing.contains($0.key.scalar?.string ?? "") }.map { ($0.key, $0.value) })
        for key in fields.keys.sorted() { node[Node(key)] = Node(fields[key]!, Tag(.str), .doubleQuoted) }
        let yaml = try Yams.serialize(node: node, allowUnicode: true).trimmingCharacters(in: .newlines)
        let markdown = "---\n" + yaml + "\n---\n\n" + (body ?? self.body)
        _ = try PortableKnowledge(markdown)
        return markdown
    }
}
