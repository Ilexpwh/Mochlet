import Foundation

/// What the analyzer (M7) produces for one source; M6 fills it from the text alone.
public struct ReportDraft: Codable, Equatable, Sendable {
    public struct Entity: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var note: String?
        public init(name: String, kind: String, note: String? = nil) {
            self.name = name
            self.kind = kind
            self.note = note
        }
    }
    public struct ActionItem: Codable, Equatable, Sendable {
        public var text: String
        public var owner: String?
        public var due: String?
        public init(text: String, owner: String? = nil, due: String? = nil) {
            self.text = text
            self.owner = owner
            self.due = due
        }
    }
    public struct Quote: Codable, Equatable, Sendable {
        public var text: String
        public var location: String?
        public init(text: String, location: String? = nil) {
            self.text = text
            self.location = location
        }
    }

    public var title: String
    public var oneLiner: String
    public var summary: String
    public var keyPoints: [String] = []
    public var whyItMatters: String?
    public var entities: [Entity] = []
    public var tags: [String] = []
    public var language: String = "en"
    public var contentKind: String = "article"
    public var suggestedProject: String?
    public var projectConfidence: Double?
    public var actionItems: [ActionItem] = []
    public var openQuestions: [String] = []
    public var quotes: [Quote] = []
    public var related: [String] = []

    enum CodingKeys: String, CodingKey {
        case title, summary, entities, tags, language, quotes, related
        case oneLiner = "one_liner"
        case keyPoints = "key_points"
        case whyItMatters = "why_it_matters"
        case contentKind = "content_kind"
        case suggestedProject = "suggested_project"
        case projectConfidence = "project_confidence"
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(title: String, oneLiner: String, summary: String) {
        self.title = title
        self.oneLiner = oneLiner
        self.summary = summary
    }

    /// A draft without a model: the first paragraph is the summary, headings are the key points.
    public static func fromText(title: String, markdown: String) -> ReportDraft {
        let doc = OKFDocument(frontmatter: OKFFrontmatter(type: "report"), body: markdown)
        let first = doc.firstParagraph ?? OneLine.collapse(markdown, limit: 300)
        var d = ReportDraft(title: title, oneLiner: OneLine.collapse(first, limit: 140), summary: String(first.prefix(600)))
        // Key points: the document's own bullets; failing that, its section headings.
        var bullets: [String] = []
        for raw in markdown.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { continue }
            let item = OneLine.collapse(String(line[m.upperBound...]), limit: 200)
            if item.count >= 8, !bullets.contains(item) { bullets.append(item) }
            if bullets.count == 10 { break }
        }
        if bullets.isEmpty {
            bullets = markdown.split(separator: "\n").filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }.prefix(8).map { String($0.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
        }
        d.keyPoints = bullets
        d.language = CJK.contains(String(markdown.prefix(600))) ? "zh" : "en"
        d.contentKind = "document"
        return d
    }
}

/// Where a report came from (frontmatter `mochlet:` block and `sources[]`).
public struct ReportProvenance: Equatable, Sendable {
    public var sourceKey: String        // sha256:… | url:… | arxiv:…
    public var resource: String?        // canonical URL or file:// path
    public var referencePath: String?   // mirrored copy, relative to the bundle
    public var mirrors: [String] = []   // further mirrors (readable .md of a binary, HTML snapshot), relative to the bundle
    public var ingestedFrom: String     // drop | url | voice | mcp | window | cli
    public var model: String?
    public var extractors: [String] = []
    public var words: Int = 0
    public var project: String?
    public var sha256: String?
    public init(sourceKey: String, resource: String? = nil, referencePath: String? = nil, ingestedFrom: String, model: String? = nil, extractors: [String] = [], words: Int = 0, project: String? = nil, sha256: String? = nil) {
        self.sourceKey = sourceKey
        self.resource = resource
        self.referencePath = referencePath
        self.ingestedFrom = ingestedFrom
        self.model = model
        self.extractors = extractors
        self.words = words
        self.project = project
        self.sha256 = sha256
    }
}

/// Renders a `type: report` page from a draft.
public enum ReportWriter {
    public static func document(_ d: ReportDraft, provenance p: ReportProvenance, now: Date = Date()) -> OKFDocument {
        var fm = OKFFrontmatter(type: "report", title: d.title, description: d.oneLiner)
        fm.resource = p.resource
        fm.tags = d.tags
        fm.status = p.model == nil ? "draft" : "stable"
        fm.generated = OKFStamp(by: p.model.map { "mochlet/2.0 (\($0))" } ?? BundleLayout.generator, at: now)
        fm.sources = [OKFSource(id: p.sourceKey, resource: p.resource ?? p.referencePath.map { "file://" + $0 }, title: d.title)]
        var m: [YAMLPair] = [YAMLPair("kind", .string(d.contentKind)), YAMLPair("ingested_from", .string(p.ingestedFrom)), YAMLPair("language", .string(d.language)), YAMLPair("integrated", .bool(false))]
        if let s = p.sha256 { m.append(YAMLPair("sha256", .string(s))) }
        if let r = p.referencePath { m.append(YAMLPair("reference", .string(r))) }
        if !p.mirrors.isEmpty { m.append(YAMLPair("mirrors", .sequence(p.mirrors.map { .string($0) }))) }
        if let u = p.resource, u.hasPrefix("http") { m.append(YAMLPair("canonical_url", .string(u))) }
        if let proj = p.project { m.append(YAMLPair("project", .string(proj))) }
        if p.words > 0 { m.append(YAMLPair("words", .int(p.words))) }
        if !p.extractors.isEmpty { m.append(YAMLPair("extractors", .sequence(p.extractors.map { .string($0) }))) }
        if let model = p.model { m.append(YAMLPair("model", .string(model))) }
        fm.mochlet = .mapping(m)

        var b = "# \(d.title)\n\n"
        let summary = d.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.hasPrefix(d.oneLiner.replacingOccurrences(of: "…", with: "")) { b += d.oneLiner + "\n\n" }
        b += "## Summary\n\n\(summary)\n\n"
        if !d.keyPoints.isEmpty { b += "## Key points\n\n" + d.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if let w = d.whyItMatters, !w.isEmpty { b += "## Why it matters\n\n\(w)\n\n" }
        if !d.entities.isEmpty {
            b += "## Entities\n\n" + d.entities.map { e in "- [[\(e.name)]] (\(e.kind))" + (e.note.map { ": \($0)" } ?? "") }.joined(separator: "\n") + "\n\n"
        }
        if !d.actionItems.isEmpty {
            b += "## Action items\n\n" + d.actionItems.map { a in "- [ ] \(a.text)" + (a.owner.map { " — \($0)" } ?? "") + (a.due.map { " (due \($0))" } ?? "") }.joined(separator: "\n") + "\n\n"
        }
        if !d.openQuestions.isEmpty { b += "## Open questions\n\n" + d.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !d.quotes.isEmpty {
            b += "## Quotes\n\n" + d.quotes.map { q in "> \(q.text)" + (q.location.map { " [^src] (\($0))" } ?? " [^src]") }.joined(separator: "\n\n") + "\n\n"
        }
        if !d.related.isEmpty { b += "## Related\n\n" + d.related.map { "- [[\($0)]]" }.joined(separator: "\n") + "\n\n" }
        b += "## Source\n\n"
        if let r = p.resource { b += "- \(r)\n" }
        if let ref = p.referencePath { b += "- mirrored copy: [\((ref as NSString).lastPathComponent)](\(relativeLink(from: "inbox/x.md", to: ref)))\n" }
        b += "\n[^src]: " + (p.resource ?? p.referencePath ?? p.sourceKey) + "\n"
        return OKFDocument(frontmatter: fm, body: b)
    }

    static func relativeLink(from: String, to: String) -> String {
        let fromDir = (from as NSString).deletingLastPathComponent
        if to.hasPrefix(fromDir + "/") { return String(to.dropFirst(fromDir.count + 1)) }
        return "../" + to
    }

    /// Source keys for dedupe.
    public static func sourceKey(sha256: String) -> String { "sha256:" + sha256 }
    public static func sourceKey(url: String) -> String { "url:" + URLCanonicalizer.canonical(url) }
}

/// Canonical URLs for dedupe: tracking parameters, fragments and `m.` hosts dropped, query sorted.
public enum URLCanonicalizer {
    static let dropped: Set<String> = ["fbclid", "gclid", "ref", "si", "mc_cid", "mc_eid", "igshid", "spm", "from", "share_token"]

    public static func canonical(_ s: String) -> String {
        guard var c = URLComponents(string: s.trimmingCharacters(in: .whitespaces)) else { return s }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        var host = c.host?.lowercased() ?? ""
        if host.hasPrefix("m.") { host = "www." + host.dropFirst(2) }
        if host.hasPrefix("mobile.") { host = "www." + host.dropFirst(7) }
        c.host = host
        if let items = c.queryItems {
            let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && !dropped.contains($0.name.lowercased()) }.sorted { $0.name < $1.name }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        if c.path.count > 1, c.path.hasSuffix("/") { c.path = String(c.path.dropLast()) }
        if (c.scheme == "http" && c.port == 80) || (c.scheme == "https" && c.port == 443) { c.port = nil }
        return c.string ?? s
    }

    public static func arxivID(_ s: String) -> String? {
        guard let c = URLComponents(string: s), (c.host ?? "").hasSuffix("arxiv.org") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "abs" || parts[0] == "pdf" else { return nil }
        var id = parts[1...].joined(separator: "/")
        if id.hasSuffix(".pdf") { id.removeLast(4) }
        if let v = id.range(of: #"v\d+$"#, options: .regularExpression) { id = String(id[..<v.lowerBound]) }
        return id
    }
}
