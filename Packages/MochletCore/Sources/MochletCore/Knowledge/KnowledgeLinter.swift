import Foundation

/// What the linter needs to know about one page.
public struct LintPage: Equatable, Sendable {
    public var path: String
    public var title: String
    public var type: String
    public var links: [String]            // resolved relative paths
    public var unresolvedLinks: [String]  // [[targets]] that matched nothing
    public var entityMentions: [String]   // names listed under "## Entities" (reports) or bold terms
    public var sourceIDs: [String]
    public var integrated: Bool           // reports: mochlet.integrated == true
    public var isHumanOwned: Bool
    public var staleAfter: Date?
    public var status: String?

    public init(path: String, title: String, type: String, links: [String] = [], unresolvedLinks: [String] = [], entityMentions: [String] = [],
                sourceIDs: [String] = [], integrated: Bool = true, isHumanOwned: Bool = false, staleAfter: Date? = nil, status: String? = nil) {
        self.path = path
        self.title = title
        self.type = type
        self.links = links
        self.unresolvedLinks = unresolvedLinks
        self.entityMentions = entityMentions
        self.sourceIDs = sourceIDs
        self.integrated = integrated
        self.isHumanOwned = isHumanOwned
        self.staleAfter = staleAfter
        self.status = status
    }
}

public struct LintFinding: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case orphan, missingPage, brokenLink, missingBacklink, notIntegrated, sourceWithoutReport, stale, contradiction, unanswered
    }
    public enum Fix: Equatable, Sendable {
        case createPage(title: String, type: String, mentionedIn: [String])
        case addBacklink(from: String, to: String)
        case linkFromIndexPage(path: String)
        case removeLink(from: String, target: String)
        case reintegrate(path: String)
        case ingest(reference: String)
        case review(path: String)
    }
    public var kind: Kind
    public var path: String
    public var detail: String
    public var fix: Fix?
    public var id: String { "\(kind.rawValue):\(path):\(detail)" }
}

/// Finds what a growing wiki accumulates: orphans, missing pages, broken links, missing
/// backlinks, reports never integrated, references without a report, stale pages.
/// Contradiction checks need a model and are supplied by the caller through `extra`.
public enum KnowledgeLinter {
    public static func lint(pages: [LintPage], references: [String] = [], reportsBySourceKey: Set<String> = [], now: Date = Date(), extra: [LintFinding] = []) -> [LintFinding] {
        var out: [LintFinding] = []
        // Lint pages quote broken links; they are not part of the graph.
        let graphPages = pages.filter { $0.type != "lint" }
        let byPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
        var inbound: [String: Set<String>] = [:]
        for p in pages { for l in p.links { inbound[l, default: []].insert(p.path) } }

        // Orphans: no inbound links from any page (reports and notes are allowed to be leaves of the index only).
        for p in graphPages where inbound[p.path, default: []].isEmpty && !["report", "note", "digest", "memory", "transcript", "log", "index", "schema"].contains(p.type) {
            out.append(LintFinding(kind: .orphan, path: p.path, detail: "no page links to \(p.title)", fix: .linkFromIndexPage(path: p.path)))
        }

        // Missing pages: the same unresolved target or entity name in ≥ 3 pages.
        var mentions: [String: Set<String>] = [:]
        for p in graphPages {
            for t in p.unresolvedLinks { mentions[t.lowercased(), default: []].insert(p.path) }
            for e in p.entityMentions where e.count >= 2 { mentions[e.lowercased(), default: []].insert(p.path) }
        }
        let existingTitles = Set(pages.map { $0.title.lowercased() } + pages.map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() })
        for (name, from) in mentions where from.count >= 3 && !existingTitles.contains(name) {
            let display = pages.flatMap { $0.unresolvedLinks + $0.entityMentions }.first { $0.lowercased() == name } ?? name
            out.append(LintFinding(kind: .missingPage, path: "entities/\(Slug.make(display)).md", detail: "“\(display)” appears in \(from.count) pages but has no page of its own",
                                   fix: .createPage(title: display, type: "entity", mentionedIn: from.sorted())))
        }

        // Broken links: unresolved targets not covered above.
        for p in graphPages {
            for t in p.unresolvedLinks where (mentions[t.lowercased()]?.count ?? 0) < 3 {
                out.append(LintFinding(kind: .brokenLink, path: p.path, detail: "[[\(t)]] does not match any page", fix: .removeLink(from: p.path, target: t)))
            }
        }

        // Missing backlinks: A links to an entity/concept B but B does not mention A.
        for p in pages {
            for l in p.links {
                guard let target = byPath[l], ["entity", "concept", "comparison", "synthesis", "overview"].contains(target.type), !target.links.contains(p.path) else { continue }
                out.append(LintFinding(kind: .missingBacklink, path: l, detail: "\(target.title) is linked from \(p.title) but does not link back", fix: .addBacklink(from: l, to: p.path)))
            }
        }

        // Reports never integrated.
        for p in pages where p.type == "report" && !p.integrated {
            out.append(LintFinding(kind: .notIntegrated, path: p.path, detail: "\(p.title) was filed but its entities and concepts were never integrated", fix: .reintegrate(path: p.path)))
        }

        // References with no report.
        for r in references where !reportsBySourceKey.contains(r) {
            out.append(LintFinding(kind: .sourceWithoutReport, path: r, detail: "a mirrored source with no report page", fix: .ingest(reference: r)))
        }

        // Stale pages.
        for p in pages {
            if let s = p.staleAfter, s < now, p.status != "deprecated" {
                out.append(LintFinding(kind: .stale, path: p.path, detail: "\(p.title) passed its stale_after date (\(OKFDate.day(s)))", fix: .review(path: p.path)))
            }
        }

        out += extra
        return out.sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) }
    }

    /// Names under `## Entities` (one per list line, before any separator) and `[[links]]` targets.
    public static func entityMentions(in body: String) -> [String] {
        var out: [String] = []
        var inEntities = false
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { inEntities = line.lowercased().contains("entities"); continue }
            if line.hasPrefix("#") { inEntities = false; continue }
            guard inEntities, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            var name = String(line.dropFirst(2))
            let cuts = [" — ", " - ", ": ", " (", "，", "：", "（"].compactMap { name.range(of: $0)?.lowerBound }
            if let first = cuts.min() { name = String(name[..<first]) }
            name = name.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            if let pipe = name.firstIndex(of: "|") { name = String(name[..<pipe]) }
            name = name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out.append(name) }
        }
        return out
    }

    /// The `type: lint` page.
    public static func render(_ findings: [LintFinding], pageCount: Int, now: Date = Date()) -> OKFDocument {
        var fm = OKFFrontmatter(type: "lint", title: "Lint \(OKFDate.day(now))")
        fm.description = findings.isEmpty ? "No problems found across \(pageCount) pages." : "\(findings.count) findings across \(pageCount) pages."
        fm.generated = OKFStamp(by: BundleLayout.generator, at: now)
        fm.status = "stable"
        var counts: [YAMLPair] = []
        for k in LintFinding.Kind.allCases {
            let n = findings.filter { $0.kind == k }.count
            if n > 0 { counts.append(YAMLPair(k.rawValue, .int(n))) }
        }
        fm.mochlet = .mapping([YAMLPair("kind", .string("lint")), YAMLPair("findings", .int(findings.count)), YAMLPair("counts", .mapping(counts))])
        var body = "# Lint \(OKFDate.day(now))\n\n"
        if findings.isEmpty { body += "Nothing to fix. \(pageCount) pages checked.\n" }
        for k in LintFinding.Kind.allCases {
            let items = findings.filter { $0.kind == k }
            guard !items.isEmpty else { continue }
            body += "## \(title(for: k)) (\(items.count))\n\n"
            for f in items {
                body += "- `\(f.path)` — \(f.detail)"
                if let fix = f.fix { body += " _(\(describe(fix)))_" }
                body += "\n"
            }
            body += "\n"
        }
        return OKFDocument(frontmatter: fm, body: body)
    }

    static func title(for k: LintFinding.Kind) -> String {
        switch k {
        case .orphan: return "Orphan pages"
        case .missingPage: return "Pages worth creating"
        case .brokenLink: return "Broken links"
        case .missingBacklink: return "Missing backlinks"
        case .notIntegrated: return "Reports never integrated"
        case .sourceWithoutReport: return "Sources without a report"
        case .stale: return "Stale pages"
        case .contradiction: return "Contradictions"
        case .unanswered: return "Questions this wiki cannot answer yet"
        }
    }

    public static func describe(_ fix: LintFinding.Fix) -> String {
        switch fix {
        case .createPage(let t, let type, _): return "create \(type) page “\(t)”"
        case .addBacklink(let from, let to): return "add a link from \(from) to \(to)"
        case .linkFromIndexPage(let p): return "link \(p) from a concept or overview"
        case .removeLink(_, let t): return "remove or fix [[\(t)]]"
        case .reintegrate(let p): return "integrate \(p)"
        case .ingest(let r): return "ingest \(r)"
        case .review(let p): return "review \(p)"
        }
    }
}
