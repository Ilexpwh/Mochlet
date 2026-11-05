import Foundation

/// The prompts behind the analyzer and the integrator (pure text; the app sends them).
public enum ReportPrompts {
    public static let analystSystem = """
    You are Mochlet's analyst. You read one source the user saved and write a faithful, specific report as JSON \
    matching the schema. Keep the language of the source for the summary and key points; keep names, numbers, \
    dates and quotes exact; never invent facts. Entities are the people, organisations, products, models and papers \
    that matter in this source. Tags are lowercase topics. The title names what the source is about, as a reader \
    would call it: never the file name, the URL or the format. Choose suggested_project from the project list only \
    when the source clearly serves that project's work.
    """

    /// The user turn: the source, the known projects and the related pages already in the knowledge base.
    public static func analyst(markdown: String, label: String, resource: String?, projects: [ProjectRouter.Candidate], related: [KnowledgeHit], maxTokens: Int = 12_000) -> String {
        var s = "Source: \(label)"
        if let resource { s += " (\(resource))" }
        s += "\n"
        if !projects.isEmpty {
            s += "\nProjects (slug — description):\n" + projects.map { "- \($0.slug) — \($0.name)" + ($0.description.isEmpty ? "" : ": \($0.description)") }.joined(separator: "\n") + "\n"
        }
        if !related.isEmpty {
            s += "\nPages already in the knowledge base that may relate (use their titles in `related`):\n" + related.map { "- \($0.title) (\($0.path)): " + OneLine.collapse($0.text, limit: 140) }.joined(separator: "\n") + "\n"
        }
        s += "\nSource text:\n\n" + truncated(markdown, maxTokens: maxTokens) + "\n\nReturn only the JSON object."
        return s
    }

    /// Map step for long sources: facts from one window.
    public static func notes(window: String, index: Int, count: Int, label: String) -> String {
        "Part \(index + 1) of \(count) of \"\(label)\". List every fact, number, name, decision, claim and quote in this part, one per line, in the source language. Return JSON {\"notes\": [...]}.\n\n" + window
    }

    /// Reduce step: analyse the notes as if they were the source.
    public static func reduce(notes: [[String]], label: String, resource: String?, projects: [ProjectRouter.Candidate], related: [KnowledgeHit]) -> String {
        let joined = notes.enumerated().map { i, n in "## Part \(i + 1)\n" + n.map { "- " + $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        return analyst(markdown: joined, label: label + " (notes from \(notes.count) parts)", resource: resource, projects: projects, related: related, maxTokens: 14_000)
    }

    public static let integratorSystem = """
    You maintain Mochlet's wiki over the user's sources. Given a new report and the related pages, propose how the \
    wiki should change: revise existing entity/concept pages with what the report adds (section-level, concise, with \
    [[wikilinks]] to the report and to other pages by title), and create pages for entities or concepts that matter and \
    have none yet (at most a few). Never restate the whole report; integrate the new facts where a reader would look for \
    them. Revise a page only when the report adds a fact, a number or a decision it lacks; a mention alone earns a \
    [[wikilink]] in the report, not a revision. A short note or checklist usually touches one or two pages. Keep every \
    page's language. Reply with the JSON plan only; an empty plan is fine when nothing should change.
    """

    public static func integrator(report: OKFDocument, reportPath: String, related: [(path: String, title: String, type: String, excerpt: String)], existingTitles: [String]) -> String {
        var s = "New report at \(reportPath):\n\n" + truncated(report.body, maxTokens: 5_000) + "\n\n"
        if !related.isEmpty {
            s += "Related pages (path · type · title):\n" + related.map { "- \($0.path) · \($0.type) · \($0.title)\n  " + OneLine.collapse($0.excerpt, limit: 300) }.joined(separator: "\n") + "\n\n"
        }
        if !existingTitles.isEmpty {
            s += "Other page titles that exist (link to them with [[Title]] instead of creating duplicates): " + existingTitles.prefix(80).joined(separator: "; ") + "\n\n"
        }
        s += "Return the JSON plan: {\"revise\": [...], \"create\": [...], \"links\": [...]}."
        return s
    }

    /// Cuts the middle out of very long text so the head and the tail survive.
    public static func truncated(_ text: String, maxTokens: Int) -> String {
        let t = TokenEstimator.estimate(text)
        guard t > maxTokens else { return text }
        let keep = Double(maxTokens) / Double(t)
        let chars = text.count
        let headLen = Int(Double(chars) * keep * 0.7)
        let tailLen = Int(Double(chars) * keep * 0.25)
        let head = String(text.prefix(headLen))
        let tail = String(text.suffix(tailLen))
        return head + "\n\n[… \(chars - headLen - tailLen) characters omitted …]\n\n" + tail
    }

    /// Windows of ≈ `tokens` for the map step, cut at paragraph boundaries.
    public static func windows(_ text: String, tokens: Int = 8_000) -> [String] {
        var out: [String] = []
        var current = ""
        var count = 0
        for para in text.components(separatedBy: "\n\n") {
            let t = TokenEstimator.estimate(para)
            if count + t > tokens, !current.isEmpty {
                out.append(current)
                current = ""
                count = 0
            }
            current += (current.isEmpty ? "" : "\n\n") + para
            count += t
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Image description for vision-capable backends.
    public static let describeImage = "Describe this image for a knowledge base: what it shows, any text in it (transcribe it), charts or numbers, and why someone might have saved it. Plain Markdown, no preamble."
}
