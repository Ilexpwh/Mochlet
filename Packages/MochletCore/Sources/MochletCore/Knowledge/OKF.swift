import Foundation

// MARK: - Dates

/// ISO-8601 with an offset, as OKF requires (`2026-11-05T17:06:04+08:00`); parses dates and date-times.
public enum OKFDate {
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return f.string(from: date)
    }

    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

// MARK: - Frontmatter

public struct OKFSource: Equatable, Sendable, Hashable {
    public var id: String
    public var resource: String?
    public var title: String?
    public var author: String?
    public var lastModified: String?
    public init(id: String, resource: String? = nil, title: String? = nil, author: String? = nil, lastModified: String? = nil) {
        self.id = id
        self.resource = resource
        self.title = title
        self.author = author
        self.lastModified = lastModified
    }
}

/// `generated: {by, at}` and each `verified: [{by, at}]` entry. Actors: `human:<id>`, `process:<id>`, `<producer>/<version>`.
public struct OKFStamp: Equatable, Sendable, Hashable {
    public var by: String
    public var at: Date
    public init(by: String, at: Date) {
        self.by = by
        self.at = at
    }
    public var isHuman: Bool { by.hasPrefix("human:") }
}

/// OKF v0.2 frontmatter: the known fields in canonical order, `mochlet:` for our extension,
/// and every unknown key preserved verbatim.
public struct OKFFrontmatter: Equatable, Sendable {
    public var type: String
    public var title: String?
    public var description: String?
    public var resource: String?
    public var tags: [String] = []
    public var status: String?
    public var staleAfter: Date?
    public var generated: OKFStamp?
    public var verified: [OKFStamp] = []
    public var sources: [OKFSource] = []
    public var okfVersion: String?
    public var mochlet: YAMLNode?
    public var unknown: [YAMLPair] = []

    public init(type: String, title: String? = nil, description: String? = nil) {
        self.type = type
        self.title = title
        self.description = description
    }

    public static let knownKeys: Set<String> = ["type", "title", "description", "resource", "tags", "status", "stale_after", "generated", "verified", "sources", "okf_version", "mochlet", "timestamp"]

    /// Human-owned pages are never overwritten by the integrator.
    public var isHumanOwned: Bool {
        if verified.contains(where: \.isHuman) { return true }
        if let g = generated, g.by.hasPrefix("human:") { return true }
        return generated == nil && verified.isEmpty && okfVersion == nil
    }

    public static func parse(_ node: YAMLNode) throws -> OKFFrontmatter {
        guard let pairs = node.pairs else { throw OKFError.frontmatterNotMapping }
        guard let type = node["type"]?.string, !type.isEmpty else { throw OKFError.missingType }
        var f = OKFFrontmatter(type: type)
        f.title = node["title"]?.string
        f.description = node["description"]?.string
        f.resource = node["resource"]?.string
        f.tags = node["tags"]?.stringArray ?? []
        f.status = node["status"]?.string
        f.staleAfter = node["stale_after"]?.string.flatMap(OKFDate.parse)
        if let g = node["generated"], let by = g["by"]?.string, let at = g["at"]?.string.flatMap(OKFDate.parse) {
            f.generated = OKFStamp(by: by, at: at)
        } else if let legacy = node["timestamp"]?.string.flatMap(OKFDate.parse) {
            // OKF v0.1 `timestamp` becomes `generated.at` on the next write.
            f.generated = OKFStamp(by: node["generated"]?["by"]?.string ?? "unknown", at: legacy)
        }
        for v in node["verified"]?.array ?? [] {
            if let by = v["by"]?.string {
                f.verified.append(OKFStamp(by: by, at: v["at"]?.string.flatMap(OKFDate.parse) ?? Date(timeIntervalSince1970: 0)))
            } else if let s = v.string {
                f.verified.append(OKFStamp(by: s, at: Date(timeIntervalSince1970: 0)))
            }
        }
        for s in node["sources"]?.array ?? [] {
            if let id = s["id"]?.string ?? s["resource"]?.string ?? s.string {
                f.sources.append(OKFSource(id: id, resource: s["resource"]?.string, title: s["title"]?.string, author: s["author"]?.string, lastModified: s["last_modified"]?.string))
            }
        }
        f.okfVersion = node["okf_version"]?.string
        f.mochlet = node["mochlet"]
        f.unknown = pairs.filter { !Self.knownKeys.contains($0.key) }
        return f
    }

    public func yaml() -> YAMLNode {
        var m: [YAMLPair] = [YAMLPair("type", .string(type))]
        if let title { m.append(YAMLPair("title", .string(title))) }
        if let description { m.append(YAMLPair("description", .string(description))) }
        if let resource { m.append(YAMLPair("resource", .string(resource))) }
        if !tags.isEmpty { m.append(YAMLPair("tags", .sequence(tags.map { .string($0) }))) }
        if let status { m.append(YAMLPair("status", .string(status))) }
        if let staleAfter { m.append(YAMLPair("stale_after", .string(OKFDate.format(staleAfter)))) }
        if let generated { m.append(YAMLPair("generated", .mapping([YAMLPair("by", .string(generated.by)), YAMLPair("at", .string(OKFDate.format(generated.at)))]))) }
        if !verified.isEmpty { m.append(YAMLPair("verified", .sequence(verified.map { .mapping([YAMLPair("by", .string($0.by)), YAMLPair("at", .string(OKFDate.format($0.at)))]) }))) }
        if !sources.isEmpty {
            m.append(YAMLPair("sources", .sequence(sources.map { s in
                var p: [YAMLPair] = [YAMLPair("id", .string(s.id))]
                if let r = s.resource { p.append(YAMLPair("resource", .string(r))) }
                if let t = s.title { p.append(YAMLPair("title", .string(t))) }
                if let a = s.author { p.append(YAMLPair("author", .string(a))) }
                if let l = s.lastModified { p.append(YAMLPair("last_modified", .string(l))) }
                return .mapping(p)
            })))
        }
        if let okfVersion { m.append(YAMLPair("okf_version", .string(okfVersion))) }
        if let mochlet, !mochlet.isNull { m.append(YAMLPair("mochlet", mochlet)) }
        m += unknown
        return .mapping(m)
    }
}

public enum OKFError: Error, CustomStringConvertible, Equatable {
    case noFrontmatter
    case frontmatterNotMapping
    case missingType
    case yaml(String)
    public var description: String {
        switch self {
        case .noFrontmatter: return "no YAML frontmatter (the file must start with ---)"
        case .frontmatterNotMapping: return "frontmatter is not a mapping"
        case .missingType: return "frontmatter has no non-empty `type`"
        case .yaml(let m): return m
        }
    }
}

// MARK: - Document

/// A Markdown page: frontmatter + body. `serialize()` writes canonical frontmatter and the body unchanged.
public struct OKFDocument: Equatable, Sendable {
    public var frontmatter: OKFFrontmatter
    public var body: String

    public init(frontmatter: OKFFrontmatter, body: String) {
        self.frontmatter = frontmatter
        self.body = body
    }

    /// Splits `---\n…\n---\n` from the body. Files without frontmatter throw (OKF conformance rule 1).
    public static func parse(_ text: String) throws -> OKFDocument {
        let (yamlText, body) = try splitFrontmatter(text)
        let node: YAMLNode
        do { node = try YAMLLite.parse(yamlText) } catch let e as YAMLLite.ParseError { throw OKFError.yaml(e.description) }
        return OKFDocument(frontmatter: try OKFFrontmatter.parse(node), body: body)
    }

    public static func splitFrontmatter(_ text: String) throws -> (yaml: String, body: String) {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        guard t.hasPrefix("---\n") || t.hasPrefix("---\r\n") else { throw OKFError.noFrontmatter }
        let afterOpen = t.index(t.startIndex, offsetBy: t.hasPrefix("---\r\n") ? 5 : 4)
        let rest = t[afterOpen...]
        // The closing fence is a line that is exactly --- (or ...).
        var searchStart = rest.startIndex
        while let nl = rest[searchStart...].firstIndex(of: "\n") ?? (searchStart < rest.endIndex ? rest.endIndex : nil) {
            let line = rest[searchStart..<nl].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line == "---" || line == "..." {
                let yaml = String(rest[rest.startIndex..<searchStart])
                let bodyStart = nl < rest.endIndex ? rest.index(after: nl) : nl
                return (yaml, String(rest[bodyStart...]))
            }
            if nl == rest.endIndex { break }
            searchStart = rest.index(after: nl)
        }
        throw OKFError.noFrontmatter
    }

    public func serialize() -> String {
        var out = "---\n" + YAMLLite.emit(frontmatter.yaml()) + "---\n"
        var b = body
        if !b.isEmpty && !b.hasPrefix("\n") { out += "\n" }
        if !b.isEmpty && !b.hasSuffix("\n") { b += "\n" }
        return out + b
    }

    /// The first `# Heading` of the body, else the frontmatter title.
    public var heading: String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# ") { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("#") { continue }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("<!--") { break }
        }
        return frontmatter.title
    }

    /// The first paragraph of prose (used for abstracts and index descriptions).
    public var firstParagraph: String? {
        var para: [String] = []
        var inFence = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !para.isEmpty { break }
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("<!--") || line.hasPrefix("|") { if para.isEmpty { continue } else { break } }
            para.append(line.trimmingCharacters(in: .whitespaces))
        }
        return para.isEmpty ? nil : para.joined(separator: " ")
    }
}

// MARK: - Links

/// `[[Page]]`, `[[Page|alias]]`, `[[Page#Heading]]`, `![[file.png]]` and local Markdown links.
public struct WikiLink: Equatable, Sendable, Hashable {
    public var target: String
    public var heading: String?
    public var alias: String?
    public var isEmbed: Bool
    public init(target: String, heading: String? = nil, alias: String? = nil, isEmbed: Bool = false) {
        self.target = target
        self.heading = heading
        self.alias = alias
        self.isEmbed = isEmbed
    }
}

public enum WikiLinks {
    static let wikiPattern = try! NSRegularExpression(pattern: #"(!?)\[\[([^\]\|#]+)(?:#([^\]\|]+))?(?:\|([^\]]+))?\]\]"#)
    static let mdPattern = try! NSRegularExpression(pattern: #"(!?)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)

    public static func extract(_ text: String) -> [WikiLink] {
        let ns = text as NSString
        return wikiPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            WikiLink(target: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces),
                     heading: m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3)),
                     alias: m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4)),
                     isEmbed: ns.substring(with: m.range(at: 1)) == "!")
        }
    }

    /// Relative Markdown link targets (not http/mailto, fragments stripped).
    public static func markdownTargets(_ text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for m in mdPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range(at: 3))
            if t.contains("://") || t.hasPrefix("mailto:") || t.hasPrefix("#") { continue }
            if let h = t.firstIndex(of: "#") { t = String(t[..<h]) }
            if !t.isEmpty { out.append(t.removingPercentEncoding ?? t) }
        }
        return out
    }

    /// Obsidian-style resolution: the page whose file name (without `.md`), slug or title matches,
    /// case-insensitively; a target with `/` is tried as a path first.
    public static func resolve(_ target: String, from documentPath: String, pages: PageCatalog) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(".md") { t.removeLast(3) }
        if t.contains("/") {
            let normalized = normalizePath(t, from: documentPath)
            if pages.paths.contains(normalized + ".md") { return normalized + ".md" }
            if pages.paths.contains(normalized) { return normalized }
            t = (t as NSString).lastPathComponent
        }
        return pages.byName[t.lowercased()]
    }

    public static func normalizePath(_ rel: String, from documentPath: String) -> String {
        var parts: [String] = []
        let baseDir = (documentPath as NSString).deletingLastPathComponent
        let start = rel.hasPrefix("/") ? [] : baseDir.split(separator: "/").map(String.init)
        for p in start + rel.split(separator: "/").map(String.init) {
            if p == "." || p.isEmpty { continue }
            if p == ".." { _ = parts.popLast(); continue }
            parts.append(p)
        }
        return parts.joined(separator: "/")
    }
}

/// Every page in the bundle by relative path, with name/slug/title lookups for link resolution.
public struct PageCatalog: Sendable, Equatable {
    public var paths: Set<String> = []
    /// lowercased file name (no .md), slug and title → relative path
    public var byName: [String: String] = [:]
    public var titles: [String: String] = [:]

    public init() {}

    public mutating func add(path: String, title: String?) {
        paths.insert(path)
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        byName[base.lowercased()] = path
        if let title, !title.isEmpty {
            byName[title.lowercased()] = byName[title.lowercased()] ?? path
            titles[path] = title
        }
    }
}
