import Foundation

/// A bounded Markdown/frontmatter envelope. Unknown YAML is preserved verbatim,
/// rather than decoded and reconstructed through a lossy dictionary.
public struct PortableKnowledge: Sendable {
    public let header: String
    public let body: String
    public init(_ markdown: String) throws {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.utf8.count <= 2_000_000, text.hasPrefix("---\n"), let boundary = text.range(of: "\n---\n") else {
            throw MochletError.message("Expected Markdown with YAML frontmatter, up to 2 MB.")
        }
        header = String(text[text.index(text.startIndex, offsetBy: 4)..<boundary.lowerBound])
        body = String(text[boundary.upperBound...]).trimmingCharacters(in: .newlines)
    }
    public func scalar(_ key: String) -> String? {
        for line in header.components(separatedBy: "\n") where line.hasPrefix(key + ":") {
            let value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if let quoted = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) { return quoted }
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            guard !value.isEmpty, !["|", ">", "[", "{", "*", "&", "!"].contains(where: { value.hasPrefix($0) }) else { return nil }
            return value.components(separatedBy: " #").first
        }
        return nil
    }
    public func replacing(_ fields: [String: String], body: String? = nil) throws -> String {
        var kept: [String] = []; var skippingContinuation = false
        for line in header.components(separatedBy: "\n") {
            if fields.keys.contains(where: { line.hasPrefix($0 + ":") }) { skippingContinuation = true; continue }
            if skippingContinuation, line.first == " " || line.first == "\t" { continue }
            if !line.isEmpty, !line.hasPrefix("#") { skippingContinuation = false }
            kept.append(line)
        }
        for key in fields.keys.sorted() {
            kept.append("\(key): \(String(decoding: try JSONEncoder().encode(fields[key]!), as: UTF8.self))")
        }
        return "---\n" + kept.joined(separator: "\n") + "\n---\n\n" + (body ?? self.body)
    }
}
