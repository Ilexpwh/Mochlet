import Foundation

/// What the brain proposes after a report is filed: revisions to existing pages, new pages, links.
public struct IntegrationPlan: Codable, Equatable, Sendable {
    public struct Revision: Codable, Equatable, Sendable {
        public var path: String
        public var section: String?
        public var mode: String          // replace | append
        public var text: String
        public var reason: String?
        public init(path: String, section: String? = nil, mode: String, text: String, reason: String? = nil) {
            self.path = path
            self.section = section
            self.mode = mode
            self.text = text
            self.reason = reason
        }
    }
    public struct NewPage: Codable, Equatable, Sendable {
        public var type: String
        public var title: String
        public var body: String
        public var description: String?
        public var tags: [String]?
        public init(type: String, title: String, body: String, description: String? = nil, tags: [String]? = nil) {
            self.type = type
            self.title = title
            self.body = body
            self.description = description
            self.tags = tags
        }
    }
    public struct Link: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }
    public var revise: [Revision] = []
    public var create: [NewPage] = []
    public var links: [Link] = []

    public init(revise: [Revision] = [], create: [NewPage] = [], links: [Link] = []) {
        self.revise = revise
        self.create = create
        self.links = links
    }

    public var isEmpty: Bool { revise.isEmpty && create.isEmpty && links.isEmpty }
}

/// Section-level Markdown edits.
public enum MarkdownSections {
    /// (heading line index, next heading index) for the section whose heading text matches (case-insensitive, `#` stripped).
    public static func range(of heading: String, in lines: [String]) -> Range<Int>? {
        let wanted = normalize(heading)
        var start: Int?
        var level = 0
        for (i, l) in lines.enumerated() {
            guard l.hasPrefix("#") else { continue }
            let lvl = l.prefix(while: { $0 == "#" }).count
            if let s = start {
                if lvl <= level { return s..<i }
                continue
            }
            if normalize(l) == wanted { start = i; level = lvl }
        }
        if let s = start { return s..<lines.count }
        return nil
    }

    static func normalize(_ heading: String) -> String {
        heading.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Replaces the body under `heading` (keeps the heading line) or appends a new section at the end.
    public static func replace(section heading: String, in body: String, with text: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let r = range(of: heading, in: lines) {
            let head = lines[r.lowerBound]
            lines.replaceSubrange(r, with: [head, ""] + newLines + [""])
            return lines.joined(separator: "\n")
        }
        return append(section: heading, to: body, text: text)
    }

    /// Appends `text` to the section (or creates `## heading` at the end).
    public static func append(section heading: String, to body: String, text: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let r = range(of: heading, in: lines) {
            var end = r.upperBound
            while end > r.lowerBound + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            // A list item after a list item continues the list; anything else starts a new paragraph.
            let lastIsItem = end > r.lowerBound + 1 && lines[end - 1].range(of: #"^\s*([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
            let firstIsItem = newLines.first?.range(of: #"^\s*([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil
            lines.insert(contentsOf: (lastIsItem && firstIsItem ? [] : [""]) + newLines, at: end)
            return lines.joined(separator: "\n")
        }
        var out = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = heading.hasPrefix("#") ? heading : "## " + heading
        out += "\n\n" + h + "\n\n" + newLines.joined(separator: "\n") + "\n"
        return out
    }

    /// Adds `[[target]]` under `## Related` unless the body links to it already.
    public static func addRelatedLink(_ target: String, to body: String) -> String {
        if body.contains("[[\(target)]]") || body.contains("[[\(target)|") { return body }
        return append(section: "Related", to: body, text: "- [[\(target)]]")
    }
}

/// Applies a plan: pages Mochlet owns are edited in place, human pages get a proposed-update block,
/// new pages are created under the right folder, links are added both ways. Pure: callers pass closures.
public enum Integrator {
    public struct Outcome: Sendable, Equatable {
        public var written: [String] = []
        public var created: [String] = []
        public var proposed: [String] = []
        public var skipped: [String] = []
        public var summary: String {
            var parts: [String] = []
            if !created.isEmpty { parts.append("\(created.count) new") }
            let revised = written.filter { !created.contains($0) }.count
            if revised > 0 { parts.append("\(revised) revised") }
            if !proposed.isEmpty { parts.append("\(proposed.count) proposed") }
            return parts.isEmpty ? "nothing to integrate" : parts.joined(separator: ", ")
        }
    }

    public struct Page: Sendable {
        public var path: String
        public var document: OKFDocument
        public var isHumanOwned: Bool
        public init(path: String, document: OKFDocument, isHumanOwned: Bool) {
            self.path = path
            self.document = document
            self.isHumanOwned = isHumanOwned
        }
    }

    public static let maxPages = 15

    /// - read: page by path or title (nil when unknown)
    /// - write: persist a page
    /// - exists: a page path exists
    public static func apply(_ plan: IntegrationPlan, reportPath: String, reportTitle: String, catalog: PageCatalog, now: Date = Date(),
                             read: (String) -> Page?, write: (String, OKFDocument) throws -> Void) rethrows -> Outcome {
        var out = Outcome()
        var touched = 0
        var titleToPath: [String: String] = [:]
        for (path, title) in catalog.titles { titleToPath[title.lowercased()] = path }

        func resolvePath(_ ref: String) -> String? {
            if catalog.paths.contains(ref) { return ref }
            if let p = titleToPath[ref.lowercased()] { return p }
            return WikiLinks.resolve(ref, from: reportPath, pages: catalog)
        }

        // 1. New pages first, so revisions can link to them.
        for p in plan.create.prefix(maxPages) {
            guard ["entity", "concept", "comparison", "overview"].contains(p.type) else { out.skipped.append(p.title); continue }
            let dir = BundleLayout.directory(forType: p.type)
            let slug = Slug.make(p.title)
            let path = "\(dir)/\(slug).md"
            if read(path) != nil || resolvePath(p.title) != nil {
                // Exists: treat as an append to Related instead of a duplicate page.
                if let existing = resolvePath(p.title) ?? Optional(path), let page = read(existing) {
                    let body = MarkdownSections.addRelatedLink(reportTitle, to: page.document.body)
                    if body != page.document.body, !page.isHumanOwned {
                        try write(existing, OKFDocument(frontmatter: page.document.frontmatter, body: body))
                        out.written.append(existing)
                    }
                }
                continue
            }
            var fm = OKFFrontmatter(type: p.type, title: p.title, description: p.description)
            fm.tags = p.tags ?? []
            fm.generated = OKFStamp(by: BundleLayout.generator, at: now)
            fm.status = "draft"
            fm.sources = [OKFSource(id: reportPath, title: reportTitle)]
            var body = p.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.hasPrefix("#") { body = "# \(p.title)\n\n" + body }
            body = MarkdownSections.addRelatedLink(reportTitle, to: body)
            try write(path, OKFDocument(frontmatter: fm, body: body + "\n"))
            out.created.append(path)
            out.written.append(path)
            titleToPath[p.title.lowercased()] = path
            touched += 1
            if touched >= maxPages { break }
        }

        // 2. Revisions.
        for r in plan.revise where touched < maxPages {
            guard let path = resolvePath(r.path), let page = read(path) else { out.skipped.append(r.path); continue }
            guard path != reportPath else { out.skipped.append(r.path); continue }
            let newBody: String
            if page.isHumanOwned {
                let proposal = (r.section.map { "**\($0)** (\(r.mode)):\n\n" } ?? "") + r.text.trimmingCharacters(in: .whitespacesAndNewlines) + (r.reason.map { "\n\n_Reason: \($0)_" } ?? "")
                newBody = SynthesisWriter.proposedUpdate(to: page.document.body, proposal: proposal, now: now)
                out.proposed.append(path)
            } else if let section = r.section, !section.isEmpty {
                newBody = r.mode == "append" ? MarkdownSections.append(section: section, to: page.document.body, text: r.text) : MarkdownSections.replace(section: section, in: page.document.body, with: r.text)
            } else if r.mode == "append" {
                newBody = page.document.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + r.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            } else {
                // Whole-body replace keeps the H1.
                let h1 = page.document.body.split(separator: "\n").first { $0.hasPrefix("# ") }.map(String.init)
                newBody = (h1.map { $0 + "\n\n" } ?? "") + r.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
            let linked = page.isHumanOwned ? newBody : MarkdownSections.addRelatedLink(reportTitle, to: newBody)
            var fm = page.document.frontmatter
            if !page.isHumanOwned {
                fm.generated = OKFStamp(by: BundleLayout.generator, at: now)
                if !fm.sources.contains(where: { $0.id == reportPath }) { fm.sources.append(OKFSource(id: reportPath, title: reportTitle)) }
            }
            try write(path, OKFDocument(frontmatter: fm, body: linked))
            out.written.append(path)
            touched += 1
        }

        // 3. Links both ways.
        for l in plan.links where touched < maxPages {
            guard let a = resolvePath(l.from), let b = resolvePath(l.to), a != b, let pa = read(a), let pb = read(b) else { continue }
            let ta = pa.document.frontmatter.title ?? ((a as NSString).lastPathComponent as NSString).deletingPathExtension
            let tb = pb.document.frontmatter.title ?? ((b as NSString).lastPathComponent as NSString).deletingPathExtension
            if !pa.isHumanOwned {
                let body = MarkdownSections.addRelatedLink(tb, to: pa.document.body)
                if body != pa.document.body { try write(a, OKFDocument(frontmatter: pa.document.frontmatter, body: body)); out.written.append(a) }
            }
            if !pb.isHumanOwned {
                let body = MarkdownSections.addRelatedLink(ta, to: pb.document.body)
                if body != pb.document.body { try write(b, OKFDocument(frontmatter: pb.document.frontmatter, body: body)); out.written.append(b) }
            }
        }
        out.written = Array(NSOrderedSet(array: out.written)) as! [String]
        return out
    }
}
