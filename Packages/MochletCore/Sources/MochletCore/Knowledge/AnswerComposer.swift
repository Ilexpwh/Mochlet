import Foundation

/// A numbered citation shown as a chip under an answer.
public struct Citation: Equatable, Sendable, Identifiable {
    public var n: Int
    public var path: String
    public var title: String
    public var heading: String
    public var lineStart: Int
    public var lineEnd: Int
    public var page: Int?
    public var timestamp: Double?
    public var resource: String?
    public var id: Int { n }

    public init(n: Int, hit: KnowledgeHit) {
        self.n = n
        path = hit.path
        title = hit.title
        heading = hit.headingPath
        lineStart = hit.lineStart
        lineEnd = hit.lineEnd
        page = hit.page
        timestamp = hit.tsStart
        resource = hit.resource
    }
}

/// Builds the prompt that turns retrieved chunks into a cited answer, and reads the citations back.
public enum AnswerComposer {
    public struct Prompt: Equatable, Sendable {
        public var system: String
        public var user: String
        public var citations: [Citation]
    }

    public static func prompt(question: String, hits: [KnowledgeHit], indexSummary: String? = nil, maxContextTokens: Int = 6000) -> Prompt {
        var citations: [Citation] = []
        var context = ""
        var used = 0
        for h in hits {
            let t = TokenEstimator.estimate(h.text)
            if used + t > maxContextTokens, !citations.isEmpty { break }
            let n = citations.count + 1
            citations.append(Citation(n: n, hit: h))
            var header = "[\(n)] \(h.title)"
            if !h.headingPath.isEmpty { header += " › \(h.headingPath)" }
            header += " (\(h.path)"
            if let p = h.page { header += ", page \(p)" }
            if let ts = h.tsStart { header += ", \(timestampText(ts))" }
            header += ")"
            context += header + "\n" + h.text + "\n\n"
            used += t
        }
        let lang = CJK.contains(question) ? "Answer in the language of the question (Chinese when the question is Chinese); keep technical terms as written in the sources." : "Answer in the language of the question."
        let system = """
        You answer questions from the user's personal knowledge base. Use only the numbered passages below; when they do not contain the answer, say what is missing instead of guessing.
        Cite every claim with the passage number in square brackets, like [2] or [1][3]. Be concise: a short answer first, then the supporting details. \(lang)
        \(indexSummary.map { "What the knowledge base contains:\n" + $0 + "\n" } ?? "")
        Passages:

        \(context)
        """
        return Prompt(system: system, user: question, citations: citations)
    }

    static let citationPattern = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)

    /// The citation numbers an answer actually used, in order of first use.
    public static func usedCitations(in answer: String, available: [Citation]) -> [Citation] {
        let ns = answer as NSString
        var seen: [Int] = []
        for m in citationPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))), available.contains(where: { $0.n == n }), !seen.contains(n) { seen.append(n) }
        }
        return seen.compactMap { n in available.first { $0.n == n } }
    }

    public static func timestampText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Turns the bilingual question into the lexical queries `search` runs (the model-based rewrite
/// in the app adds to these).
public enum QueryPlanner {
    public static func lexicalVariants(_ question: String) -> [String] {
        var out = [question]
        let stripped = question.replacingOccurrences(of: #"[?？。！!,，、:：]"#, with: " ", options: .regularExpression)
        if stripped != question { out.append(stripped) }
        // Question words add noise to BM25.
        let noise = ["what", "which", "who", "when", "where", "why", "how", "does", "do", "is", "are", "the", "a", "an", "of", "in", "on", "for", "to", "about", "tell", "me",
                     "什么", "哪个", "哪些", "谁", "什么时候", "为什么", "怎么", "如何", "是", "的", "了", "吗", "呢", "请", "介绍", "一下", "关于"]
        var words = stripped.split(separator: " ").map(String.init).filter { !noise.contains($0.lowercased()) }
        for n in noise where n.count >= 2 && CJK.contains(n) { words = words.map { $0.replacingOccurrences(of: n, with: " ") } }
        let keywords = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !keywords.isEmpty, keywords != stripped { out.append(keywords) }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// Merges the hit lists of several queries, keeping the best score per chunk.
    public static func merge(_ lists: [[KnowledgeHit]], k: Int) -> [KnowledgeHit] {
        var best: [Int: KnowledgeHit] = [:]
        for (li, list) in lists.enumerated() {
            for (rank, h) in list.enumerated() {
                var scored = h
                scored.score = 1 / (60 + Double(rank + 1)) + (li == 0 ? 0.002 : 0)
                if let b = best[h.chunkID] { scored.score += b.score }
                best[h.chunkID] = scored
            }
        }
        var perDoc: [String: Int] = [:]
        var out: [KnowledgeHit] = []
        for h in best.values.sorted(by: { $0.score > $1.score }) {
            if perDoc[h.path, default: 0] >= 2 { continue }
            perDoc[h.path, default: 0] += 1
            out.append(h)
            if out.count >= k { break }
        }
        return out
    }
}

/// "File this answer": a `synthesis` page with the question as title and the citations as sources.
public enum SynthesisWriter {
    public static func page(question: String, answer: String, citations: [Citation], existingSlugs: Set<String>, now: Date = Date()) -> (slug: String, document: OKFDocument) {
        let title = OneLine.collapse(question, limit: 120)
        let slug = Slug.unique(Slug.make(title), taken: existingSlugs)
        var fm = OKFFrontmatter(type: "synthesis", title: title)
        fm.description = OneLine.collapse(answer.split(separator: "\n").first.map(String.init) ?? answer, limit: 200)
        fm.generated = OKFStamp(by: BundleLayout.generator, at: now)
        fm.status = "draft"
        fm.tags = ["synthesis"]
        var seenPaths: Set<String> = []
        for c in citations where !seenPaths.contains(c.path) {
            seenPaths.insert(c.path)
            fm.sources.append(OKFSource(id: c.path, resource: c.resource, title: c.title))
        }
        fm.mochlet = .mapping([YAMLPair("kind", .string("synthesis")), YAMLPair("question", .string(question)), YAMLPair("filed_at", .string(OKFDate.format(now)))])
        var body = "# \(title)\n\n" + answer.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Sources\n\n"
        for c in citations {
            let name = ((c.path as NSString).lastPathComponent as NSString).deletingPathExtension
            // Pages get a wikilink; a mirrored source under references/ is not a page, so it gets a plain relative link.
            let link = KnowledgeBundle.isReference(c.path) ? "[\(c.title)](../\(c.path))" : "[[\(name)|\(c.title)]]"
            var line = "- [\(c.n)] \(link)"
            if !c.heading.isEmpty { line += " › \(c.heading)" }
            if let p = c.page { line += " (page \(p))" }
            if let ts = c.timestamp { line += " (\(AnswerComposer.timestampText(ts)))" }
            body += line + "\n"
        }
        return (slug, OKFDocument(frontmatter: fm, body: body))
    }

    /// The line added to each cited page under `## Mentioned in` (backlink).
    public static func backlinkLine(synthesisSlug: String, title: String) -> String { "- [[\(synthesisSlug)|\(title)]]" }

    /// Appends a backlink under `## Mentioned in` (creating the section) unless it is already there.
    public static func addBacklink(to body: String, line: String) -> String {
        if body.contains(line) { return body }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## mentioned in" }) {
            var at = h + 1
            while at < lines.count, lines[at].trimmingCharacters(in: .whitespaces).isEmpty || lines[at].hasPrefix("- ") { at += 1 }
            while at > h + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(line, at: at)
            return lines.joined(separator: "\n")
        }
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        out += "\n## Mentioned in\n\n" + line + "\n"
        return out
    }

    /// Human-owned pages get a proposal block instead of an edit.
    public static func proposedUpdate(to body: String, proposal: String, now: Date = Date()) -> String {
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        return out + "\n## Proposed update (\(OKFDate.day(now)))\n\n" + proposal.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
