import Foundation
import Testing
@testable import MochletCore

// MARK: - HTML → Markdown

@Test func htmlToMarkdownKeepsStructure() {
    let html = """
    <html><head><title>T</title><meta property="og:title" content="A Page"><meta name="author" content="Ada"></head>
    <body><nav><a href="/x">Skip me</a></nav>
    <article><h1>Hello &amp; welcome</h1><p>First <strong>bold</strong> and <em>em</em> with a <a href="/rel">link</a>.</p>
    <ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>
    <pre><code class="language-swift">let x = 1</code></pre>
    <table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>
    <blockquote>quoted</blockquote></article>
    <footer>footer text</footer></body></html>
    """
    let md = HTMLToMarkdown.convert(html, baseURL: URL(string: "https://example.com/dir/page"))
    #expect(md.contains("# Hello & welcome"))
    #expect(md.contains("**bold**"))
    #expect(md.contains("*em*") || md.contains("_em_"))
    #expect(md.contains("[link](https://example.com/rel)"))
    #expect(md.contains("- one"))
    #expect(md.contains("  - nested"))
    #expect(md.contains("```swift\nlet x = 1\n```"))
    #expect(md.contains("| a | b |"))
    #expect(md.contains("> quoted"))
    #expect(!md.contains("Skip me"))
    #expect(!md.contains("footer text"))
    let meta = HTMLToMarkdown.headMetadata(html)
    #expect(meta["og:title"] == "A Page")
    #expect(meta["author"] == "Ada")
}

@Test func readerHeuristicsPickTheArticle() {
    let html = """
    <html><body><div class="sidebar"><a href="/a">a</a><a href="/b">b</a><a href="/c">c</a> short</div>
    <div class="post"><p>\(String(repeating: "Real article text. ", count: 40))</p><p>\(String(repeating: "More text. ", count: 40))</p></div>
    <div class="comments"><p>\(String(repeating: "comment ", count: 60))</p></div></body></html>
    """
    let main = ReaderHeuristics.mainContent(html)
    #expect(main.contains("Real article text"))
    #expect(!main.contains("comment comment"))
}

@Test func entitiesDecode() {
    #expect(HTMLToMarkdown.decodeEntities("a &lt; b &amp; &#39;c&#39; &#xe9;&nbsp;x") == "a < b & 'c' é\u{00A0}x")
}

// MARK: - URL routing

@Test func urlRoutes() {
    if case .arxiv(let id, _, let pdf) = URLRoute.route(URL(string: "https://arxiv.org/abs/2401.12345v2")!) {
        #expect(id == "2401.12345")
        #expect(pdf.absoluteString.contains("pdf/2401.12345"))
    } else { Issue.record("arxiv abs not routed") }
    if case .arxiv(let id, _, _) = URLRoute.route(URL(string: "https://arxiv.org/pdf/2401.12345")!) { #expect(id == "2401.12345") } else { Issue.record("arxiv pdf not routed") }
    if case .gitHubRepo(let o, let r) = URLRoute.route(URL(string: "https://github.com/Ilexpwh/Mochlet")!) { #expect(o == "Ilexpwh" && r == "Mochlet") } else { Issue.record("github repo") }
    if case .gitHubBlob(let raw, let path) = URLRoute.route(URL(string: "https://github.com/Ilexpwh/Mochlet/blob/main/README.md")!) {
        #expect(raw.absoluteString == "https://raw.githubusercontent.com/Ilexpwh/Mochlet/main/README.md")
        #expect(path == "README.md")
    } else { Issue.record("github blob") }
    if case .youTube(let id) = URLRoute.route(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=1")!) { #expect(id == "dQw4w9WgXcQ") } else { Issue.record("youtu.be") }
    if case .youTube(let id) = URLRoute.route(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=x")!) { #expect(id == "dQw4w9WgXcQ") } else { Issue.record("youtube watch") }
    if case .pdf = URLRoute.route(URL(string: "https://example.com/paper.PDF")!) {} else { Issue.record("pdf") }
    if case .page = URLRoute.route(URL(string: "https://example.com/post?utm_source=x")!) {} else { Issue.record("page") }
}

@Test func robotsRules() {
    let r = RobotsRules.parse("""
    User-agent: *
    Disallow: /private/
    Allow: /private/public-note
    Disallow: /*.json$

    User-agent: Mochlet
    Disallow: /only-for-mochlet
    """)
    // A group for Mochlet replaces the generic one (robots.txt semantics).
    #expect(r.allows(path: "/"))
    #expect(r.allows(path: "/private/x"))
    #expect(!r.allows(path: "/only-for-mochlet"))
    let g = RobotsRules.parse("User-agent: *\nDisallow: /private/\nAllow: /private/public-note\nDisallow: /*.json$\n")
    #expect(!g.allows(path: "/private/x"))
    #expect(g.allows(path: "/private/public-note"))
    #expect(!g.allows(path: "/data/file.json"))
    #expect(g.allows(path: "/data/file.json?x"))
    #expect(RobotsRules.parse("").allows(path: "/anything"))
    #expect(LanguageGuess.code("English text with an accented café in it, nothing more than that here.") == "en")
}

// MARK: - Structured output

@Test func jsonRepairExtractsObjects() {
    #expect(JSONRepair.extractObject("Sure! ```json\n{\"a\": 1}\n``` done")?["a"].int == 1)
    #expect(JSONRepair.extractObject("prefix {\"a\": {\"b\": [1, 2]}} suffix")?["a"]["b"][1].int == 2)
    #expect(JSONRepair.extractObject("{\"a\": \"unterminated")?["a"].string == "unterminated")
    #expect(JSONRepair.extractObject("no json here") == nil)
}

@Test func reportSchemaDecodesIntoDraft() {
    let text = """
    {"title":"Paper","one_liner":"A paper.","summary":"Long.","key_points":["k1"],"entities":[{"name":"Ada","kind":"person"}],
     "tags":["ML"],"language":"en","content_kind":"paper","suggested_project":"x","project_confidence":0.4,"action_items":[],"open_questions":["q"],"quotes":[{"text":"t","location":"p1"}],"related":[]}
    """
    let d = JSONRepair.decode(ReportDraft.self, from: text)
    #expect(d?.title == "Paper")
    #expect(d?.entities.first?.name == "Ada")
    #expect(d?.projectConfidence == 0.4)
    #expect(Schemas.report["required"].array?.contains(.string("title")) == true)
}

@Test func decisionPromptParses() throws {
    let opts = [DecisionOption(id: "mochlet", description: "The notch app"), DecisionOption(id: "inbox", description: "none")]
    let a = try DecisionPrompt.parse("{\"choice\": \"mochlet\", \"confidence\": 0.9}", options: opts, backend: "t")
    #expect(a.choice == "mochlet")
    #expect(a.probabilities["inbox"]! < 0.2)
    #expect(a.margin > 0.7)
    let b = try DecisionPrompt.parse("I would say inbox.", options: opts, backend: "t")
    #expect(b.choice == "inbox")
    #expect(throws: DecisionError.self) { try DecisionPrompt.parse("nothing", options: opts, backend: "t") }
}

// MARK: - Project router

@Test func projectRouterAsksWhenUnsure() {
    let c = [ProjectRouter.Candidate(slug: "a", name: "A", description: "alpha"), ProjectRouter.Candidate(slug: "b", name: "B", description: "beta")]
    let sure = ProjectRouter.verdict(answer: DecisionAnswer(choice: "a", confidence: 0.9, probabilities: ["a": 0.9, "b": 0.05, "inbox": 0.05], backend: "t"), candidates: c, priors: [], priorKeys: [])
    #expect(sure.slug == "a" && !sure.ask)
    let close = ProjectRouter.verdict(answer: DecisionAnswer(choice: "a", confidence: 0.5, probabilities: ["a": 0.5, "b": 0.45, "inbox": 0.05], backend: "t"), candidates: c, priors: [], priorKeys: [])
    #expect(close.ask)
    #expect(close.question?.options.first?.slug == "a")
    #expect(close.question?.options.contains { $0.slug == nil } == true)
    // A strong host prior flips the pick.
    let prior = ProjectRouter.verdict(answer: DecisionAnswer(choice: "a", confidence: 0.55, probabilities: ["a": 0.55, "b": 0.4, "inbox": 0.05], backend: "t"), candidates: c,
                                      priors: [(key: "host:github.com", project: "b", weight: 3)], priorKeys: ["host:github.com"])
    #expect(prior.slug == "b")
    let inbox = ProjectRouter.verdict(answer: DecisionAnswer(choice: "inbox", confidence: 0.9, probabilities: ["a": 0.05, "b": 0.05, "inbox": 0.9], backend: "t"), candidates: c, priors: [], priorKeys: [])
    #expect(inbox.slug == nil && !inbox.ask)
    let deltas = ProjectRouter.priorDeltas(keys: ["host:x", "tag:y"], chosen: "b", rejected: "a")
    #expect(deltas.count == 4)
    #expect(deltas.contains { $0.project == "b" && $0.delta > 0 } && deltas.contains { $0.project == "a" && $0.delta < 0 })
    let req = ProjectRouter.request(draft: ReportDraft(title: "T", oneLiner: "o", summary: "s"), host: "github.com", sourceDirectory: nil, candidates: c)
    #expect(req.options.count == 3 && req.options.last?.id == "inbox")
    #expect(PriorKeys.keys(host: "GitHub.com", tags: ["ML"], sourceDirectory: "/x") == ["host:github.com", "tag:ml", "dir:/x"])
}

// MARK: - Prompts

@Test func promptWindowsAndTruncation() {
    let para = String(repeating: "word ", count: 400)   // ≈ 520 tokens
    let text = (0..<20).map { _ in para }.joined(separator: "\n\n")
    let windows = ReportPrompts.windows(text, tokens: 2000)
    #expect(windows.count >= 5 && windows.count <= 7)
    #expect(windows.joined(separator: "\n\n").count == text.count)
    let cut = ReportPrompts.truncated(text, maxTokens: 1000)
    #expect(cut.count < text.count / 4)
    #expect(cut.contains("characters omitted"))
}

// MARK: - Sections and the integrator

@Test func markdownSectionsReplaceAndAppend() {
    let body = "# Title\n\nIntro.\n\n## Facts\n\n- a\n\n## Related\n\n- [[x]]\n"
    let replaced = MarkdownSections.replace(section: "Facts", in: body, with: "- b\n- c")
    #expect(replaced.contains("## Facts\n\n- b\n- c\n") && replaced.contains("## Related"))
    let appended = MarkdownSections.append(section: "Facts", to: body, text: "- d")
    #expect(appended.contains("- a\n- d") || appended.contains("- a\n\n- d"))
    let added = MarkdownSections.append(section: "New", to: body, text: "fresh")
    #expect(added.contains("## New\n\nfresh"))
    let linked = MarkdownSections.addRelatedLink("Some Page", to: "# T\n\nbody\n")
    #expect(linked.contains("[[Some Page]]"))
    #expect(MarkdownSections.addRelatedLink("Some Page", to: linked) == linked)
}

@Test func integratorRevisesCreatesAndProposes() throws {
    var catalog = PageCatalog()
    catalog.add(path: "entities/ada.md", title: "Ada Lovelace")
    catalog.add(path: "concepts/engines.md", title: "Analytical Engines")
    catalog.add(path: "inbox/report.md", title: "The Report")
    var pages: [String: Integrator.Page] = [
        "entities/ada.md": Integrator.Page(path: "entities/ada.md", document: OKFDocument(frontmatter: OKFFrontmatter(type: "entity", title: "Ada Lovelace"), body: "# Ada Lovelace\n\n## Facts\n\n- born 1815\n"), isHumanOwned: false),
        "concepts/engines.md": Integrator.Page(path: "concepts/engines.md", document: OKFDocument(frontmatter: OKFFrontmatter(type: "concept", title: "Analytical Engines"), body: "# Analytical Engines\n\nHuman text.\n"), isHumanOwned: true),
        "inbox/report.md": Integrator.Page(path: "inbox/report.md", document: OKFDocument(frontmatter: OKFFrontmatter(type: "report", title: "The Report"), body: "# The Report\n"), isHumanOwned: false),
    ]
    let plan = IntegrationPlan(
        revise: [IntegrationPlan.Revision(path: "Ada Lovelace", section: "Facts", mode: "append", text: "- wrote the first program [[The Report]]", reason: "new fact"),
                 IntegrationPlan.Revision(path: "concepts/engines.md", section: nil, mode: "append", text: "Engines were programmable.", reason: nil)],
        create: [IntegrationPlan.NewPage(type: "entity", title: "Charles Babbage", body: "Designed the engine.", description: "Inventor", tags: ["person"]),
                 IntegrationPlan.NewPage(type: "report", title: "Not allowed", body: "x", description: nil, tags: nil)],
        links: [IntegrationPlan.Link(from: "Ada Lovelace", to: "Charles Babbage")])
    let outcome = try Integrator.apply(plan, reportPath: "inbox/report.md", reportTitle: "The Report", catalog: catalog, read: { pages[$0] }, write: { path, doc in
        pages[path] = Integrator.Page(path: path, document: doc, isHumanOwned: pages[path]?.isHumanOwned ?? false)
    })
    #expect(outcome.created == ["entities/charles-babbage.md"])
    #expect(outcome.proposed == ["concepts/engines.md"])
    #expect(outcome.skipped.contains("Not allowed"))
    let ada = pages["entities/ada.md"]!.document.body
    #expect(ada.contains("- born 1815\n- wrote the first program [[The Report]]"))
    #expect(ada.contains("[[Charles Babbage]]"))
    #expect(pages["entities/charles-babbage.md"]!.document.body.contains("[[Ada Lovelace]]"))
    #expect(pages["entities/charles-babbage.md"]!.document.frontmatter.sources.first?.id == "inbox/report.md")
    let engines = pages["concepts/engines.md"]!.document.body
    #expect(engines.contains("Human text.") && engines.contains("## Proposed update") && engines.contains("Engines were programmable."))
    #expect(!outcome.summary.isEmpty)
}

@Test func integratorRespectsTheBudget() throws {
    var catalog = PageCatalog()
    var pages: [String: Integrator.Page] = [:]
    catalog.add(path: "inbox/r.md", title: "R")
    pages["inbox/r.md"] = Integrator.Page(path: "inbox/r.md", document: OKFDocument(frontmatter: OKFFrontmatter(type: "report", title: "R"), body: "# R\n"), isHumanOwned: false)
    let plan = IntegrationPlan(revise: [], create: (0..<30).map { IntegrationPlan.NewPage(type: "entity", title: "Entity \($0)", body: "b", description: nil, tags: nil) }, links: [])
    let outcome = try Integrator.apply(plan, reportPath: "inbox/r.md", reportTitle: "R", catalog: catalog, read: { pages[$0] }, write: { pages[$0] = Integrator.Page(path: $0, document: $1, isHumanOwned: false) })
    #expect(outcome.created.count == Integrator.maxPages)
}

// MARK: - Bundle path safety

@Test func bundleRefusesUnsafePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-safe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let b = KnowledgeBundle(root: root)
    _ = try b.bootstrap()
    #expect(throws: BundleError.self) { try b.read("../outside.md") }
    #expect(throws: BundleError.self) { try b.write(text: "x", to: "/etc/passwd") }
    #expect(throws: BundleError.self) { try b.write(text: "x", to: "inbox/../../escape.md") }
    #expect(KnowledgeBundle.isValidSlug("my-project-2"))
    #expect(!KnowledgeBundle.isValidSlug("../x") && !KnowledgeBundle.isValidSlug("") && !KnowledgeBundle.isValidSlug("A B"))
}
