import Foundation
import Testing
@testable import MochletCore

@Suite struct YAMLLiteTests {
    @Test func parsesTheFrontmatterShapesOKFUses() throws {
        let text = """
        type: report
        title: "Quoted: title"   # comment
        description: A plain description with: colon inside
        tags: [ai, "two words", café]
        status: draft
        generated:
          by: mochlet/2.0
          at: 2026-11-05T17:06:04+08:00
        verified:
          - by: human:ilex
            at: 2026-11-06T01:00:00+08:00
        sources:
          - id: sha256:abc
            resource: https://example.com/a?b=1#x
            title: 'It''s quoted'
        count: 3
        ratio: 0.5
        flag: true
        nothing: ~
        notes: |
          line one
          line two
        folded: >-
          a
          b
        """
        let n = try YAMLLite.parse(text)
        #expect(n["type"] == .string("report"))
        #expect(n["title"] == .string("Quoted: title"))
        #expect(n["description"] == .string("A plain description with: colon inside"))
        #expect(n["tags"]?.stringArray == ["ai", "two words", "café"])
        #expect(n["generated"]?["by"] == .string("mochlet/2.0"))
        #expect(n["verified"]?.array?.first?["by"] == .string("human:ilex"))
        #expect(n["sources"]?.array?.first?["title"] == .string("It's quoted"))
        #expect(n["sources"]?.array?.first?["resource"] == .string("https://example.com/a?b=1#x"))
        #expect(n["count"] == .int(3))
        #expect(n["ratio"] == .double(0.5))
        #expect(n["flag"] == .bool(true))
        #expect(n["nothing"] == .null)
        #expect(n["notes"] == .string("line one\nline two\n"))
        #expect(n["folded"] == .string("a b"))
    }

    @Test func roundTripsUnknownKeysInOrder() throws {
        let text = "type: entity\nzeta: 1\nalpha:\n  - x\n  - y: 2\n    z: [1, 2]\nname: \"needs: quoting\"\n"
        let n = try YAMLLite.parse(text)
        let emitted = YAMLLite.emit(n)
        let again = try YAMLLite.parse(emitted)
        #expect(again == n)
        #expect(n.pairs?.map(\.key) == ["type", "zeta", "alpha", "name"])
        #expect(emitted.contains("name: \"needs: quoting\""))
    }

    @Test func quotesValuesThatWouldChangeType() throws {
        for s in ["true", "123", "1.5", "null", "", " lead", "- dash", "a: b", "#hash", "2026-11-05"] {
            let emitted = YAMLLite.emit(.mapping([YAMLPair("k", .string(s))]))
            let back = try YAMLLite.parse(emitted)
            #expect(back["k"] == .string(s), "\(s) → \(emitted)")
        }
    }

    @Test func flowMappingsAndEmptyCollections() throws {
        let n = try YAMLLite.parse("a: {x: 1, y: [a, b]}\nb: []\nc: {}\n")
        #expect(n["a"]?["x"] == .int(1))
        #expect(n["a"]?["y"]?.stringArray == ["a", "b"])
        #expect(n["b"] == .sequence([]))
        #expect(n["c"] == .mapping([]))
        #expect(YAMLLite.emit(n) == "a:\n  x: 1\n  y:\n    - a\n    - b\nb: []\nc: {}\n")
    }

    @Test func reportsBadIndentation() {
        #expect(throws: YAMLLite.ParseError.self) { try YAMLLite.parse("a: 1\n  b: 2\n") }
    }
}

@Suite struct OKFTests {
    @Test func parsesAndSerialisesCanonically() throws {
        let text = """
        ---
        custom_first: keep me
        type: report
        title: A report
        timestamp: 2026-11-01T10:00:00+08:00
        tags: [a]
        mochlet:
          kind: report
          sha256: abc
        ---

        # A report

        First paragraph here.
        """
        let doc = try OKFDocument.parse(text)
        #expect(doc.frontmatter.type == "report")
        #expect(doc.frontmatter.generated?.by == "unknown")   // legacy timestamp → generated.at
        #expect(doc.frontmatter.unknown.map(\.key) == ["custom_first"])
        #expect(doc.frontmatter.mochlet?["sha256"] == .string("abc"))
        #expect(doc.heading == "A report")
        #expect(doc.firstParagraph == "First paragraph here.")
        let out = doc.serialize()
        #expect(out.hasPrefix("---\ntype: report\ntitle: A report\ntags:\n  - a\ngenerated:\n"))
        #expect(out.contains("custom_first: keep me\n---\n"))
        #expect(!out.contains("timestamp:"))
        let again = try OKFDocument.parse(out)
        #expect(again.frontmatter == doc.frontmatter)
        #expect(again.body.trimmingCharacters(in: .whitespacesAndNewlines) == doc.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func rejectsPagesWithoutFrontmatterOrType() {
        #expect(throws: OKFError.self) { try OKFDocument.parse("# no frontmatter\n") }
        #expect(throws: OKFError.self) { try OKFDocument.parse("---\ntitle: x\n---\n") }
    }

    @Test func humanOwnership() throws {
        var fm = OKFFrontmatter(type: "concept")
        #expect(fm.isHumanOwned)   // no stamps at all → a human wrote it
        fm.generated = OKFStamp(by: "mochlet/2.0", at: Date())
        #expect(!fm.isHumanOwned)
        fm.verified = [OKFStamp(by: "human:ilex", at: Date())]
        #expect(fm.isHumanOwned)
    }

    @Test func wikilinksResolveLikeObsidian() {
        var cat = PageCatalog()
        cat.add(path: "entities/openai.md", title: "OpenAI")
        cat.add(path: "concepts/rag.md", title: "Retrieval-augmented generation")
        let links = WikiLinks.extract("See [[OpenAI]], [[rag|RAG]], [[Retrieval-augmented generation#History]] and ![[references/x.png]] and [[Nope]].")
        #expect(links.count == 5)
        #expect(links[1].alias == "RAG")
        #expect(links[2].heading == "History")
        #expect(links[3].isEmbed)
        #expect(WikiLinks.resolve("OpenAI", from: "inbox/a.md", pages: cat) == "entities/openai.md")
        #expect(WikiLinks.resolve("rag", from: "inbox/a.md", pages: cat) == "concepts/rag.md")
        #expect(WikiLinks.resolve("../concepts/rag.md", from: "inbox/a.md", pages: cat) == "concepts/rag.md")
        #expect(WikiLinks.resolve("Nope", from: "inbox/a.md", pages: cat) == nil)
        #expect(WikiLinks.markdownTargets("[a](../concepts/rag.md#x) [b](https://x.y) [c](#frag)") == ["../concepts/rag.md"])
    }

    @Test func indexAndLogFiles() throws {
        let entries = [IndexEntry(path: "b.md", title: "Beta", description: "second", type: "report", sourceCount: 2), IndexEntry(path: "a.md", title: "Alpha", type: "entity")]
        let idx = OKFIndexFile.render(directory: "", title: "Knowledge", entries: entries, subdirectories: [IndexSubdirectory(name: "inbox", abstract: "Reports.", pageCount: 2)], isRoot: true, now: Date(timeIntervalSince1970: 0))
        let doc = try OKFDocument.parse(idx)
        #expect(doc.frontmatter.type == "index")
        #expect(doc.frontmatter.okfVersion == "0.2")
        #expect(idx.contains("## Reports\n\n* [Beta](b.md) - second (sources: 2)\n"))
        #expect(idx.contains("## Entities\n\n* [Alpha](a.md)\n"))
        #expect(idx.contains("* [inbox/](inbox/index.md) - Reports. (2 pages)"))
        #expect(idx.contains("1 reports · 1 entities"))

        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let t1 = Date(timeIntervalSince1970: 1_793_000_000)
        var log = OKFLogFile.append(nil, kind: "ingest", text: "Paper → inbox/paper.md", now: t1, timeZone: tz)
        log = OKFLogFile.append(log, kind: "query", text: "what is x? → syntheses/what-is-x.md", now: t1.addingTimeInterval(60), timeZone: tz)
        log = OKFLogFile.append(log, kind: "lint", text: "3 orphans", now: t1.addingTimeInterval(86_400), timeZone: tz)
        let body = try OKFDocument.parse(log).body
        let lines = body.split(separator: "\n").map(String.init)
        let d1 = OKFDate.day(t1, timeZone: tz), d2 = OKFDate.day(t1.addingTimeInterval(86_400), timeZone: tz)
        #expect(lines.firstIndex(of: "## \(d2)")! < lines.firstIndex(of: "## \(d1)")!)   // newest first
        #expect(lines.contains { $0.hasSuffix("ingest | Paper → inbox/paper.md") })
        #expect(lines.filter { $0.hasPrefix("- ") }.count == 3)
    }

    @Test func bootstrapWritesSchemaAndIndexes() {
        let files = BundleBootstrap.files()
        #expect(files.contains { $0.relativePath == "SCHEMA.md" && $0.contents.contains("human-owned") })
        #expect(files.contains { $0.relativePath == "CLAUDE.md" })
        #expect(files.contains { $0.relativePath == "inbox/index.md" })
        for f in files where f.relativePath.hasSuffix(".md") && f.relativePath != "SCHEMA.md" && !BundleLayout.agentCopies.contains(f.relativePath) {
            #expect((try? OKFDocument.parse(f.contents)) != nil, Comment(rawValue: f.relativePath))
        }
    }
}

@Suite struct ChunkerTests {
    @Test func respectsBoundsAndHeadings() {
        var md = "# Title\n\nIntro paragraph.\n\n## Section A\n\n"
        for i in 0..<60 { md += "Paragraph \(i) with enough words to count for something in the estimate of tokens here.\n\n" }
        md += "```swift\nlet x = 1\n```\n\n## Section B\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- item one\n- item two\n  continued\n"
        let chunks = Chunker().chunk(md)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.tokenCount <= 1024 })
        #expect(chunks.first?.headingPath == "Title")
        #expect(chunks.contains { $0.headingPath == "Title > Section A" })
        #expect(chunks.last?.headingPath == "Title > Section B")
        #expect(chunks.contains { $0.text.contains("| a | b |") })
        #expect(chunks.first?.lineStart == 3)
        // Overlap: the chunk cut for size (inside Section A) starts with the previous chunk's last block.
        let prevLast = chunks[0].text.components(separatedBy: "\n\n").last!
        #expect(chunks[1].text.hasPrefix(prevLast))
        #expect(chunks[1].headingPath == "Title > Section A")
    }

    @Test func pageMarkersAndTokenEstimate() {
        let chunks = Chunker().chunk("<!-- page: 3 -->\nSome text\n\n<!-- page: 4 -->\nMore text")
        #expect(chunks.first?.page == 3)
        #expect(TokenEstimator.estimate("hello world") == 3)
    }

    @Test func queryPatternsPrefixLongerWords() {
        let q = QueryPatternBuilder.build("machine learning pro")!
        // Words of four letters or more match as prefixes; shorter ones must stand whole.
        #expect(q.terms == ["\"machine\"*", "\"learning\"*", "\"pro\""])
        #expect(QueryPatternBuilder.build("!!") == nil)
    }

    @Test func transcriptChunksByTimeAndOverlap() {
        var turns: [TranscriptTurn] = []
        for i in 0..<10 {
            let start = Double(i * 30)
            turns.append(TranscriptTurn(speaker: i % 2 == 0 ? "me" : "p2", start: start, end: start + 25, text: "turn \(i)"))
        }
        let chunks = TranscriptChunker.chunk(turns)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { $0.tsEnd - $0.tsStart <= 120 })
        #expect(chunks[1].text.hasPrefix(chunks[0].text.split(separator: "\n").last!))
    }
}

@Suite struct KnowledgeIndexTests {
    func doc(_ path: String, _ title: String, type: String = "report", links: [String] = []) -> IndexedDocument {
        IndexedDocument(path: path, type: type, title: title, sha256: "s", mtime: Date(), size: 1, links: links)
    }

    @Test func findsPagesAndFuses() throws {
        let index = try KnowledgeIndex.inMemory()
        try index.upsert(doc("inbox/a.md", "Apple Vision Pro review"), chunks: Chunker().chunk("Apple released the Vision Pro headset, priced at $3,499. Machine learning models run on the device."))
        try index.upsert(doc("inbox/b.md", "RAG notes", type: "concept"), chunks: Chunker().chunk("Retrieval-augmented generation combines search with a language model. Chunks are embedded and ranked."))
        try index.upsert(doc("inbox/c.md", "Unrelated"), chunks: Chunker().chunk("A recipe for bread: flour, water, salt."))
        #expect(index.documentCount == 3)
        #expect(try index.find("machine learning").first?.path == "inbox/a.md")
        #expect(try index.find("headset").first?.path == "inbox/a.md")
        #expect(try index.find("retrieval").first?.path == "inbox/b.md")
        #expect(try index.find("Vision Pro price").first?.path == "inbox/a.md") // prefix match on "priced"
        #expect(try index.find("retrieval", filters: FindFilters(types: ["report"])).isEmpty)
        #expect(try index.find("zzzz").isEmpty)
        // A vector list fused with BM25 changes the order when it disagrees.
        var store = VectorStore(model: "t", dimension: 2)
        let cID = try index.db.query("SELECT c.id AS id FROM chunks c JOIN documents d ON d.id = c.document_id WHERE d.path = 'inbox/c.md'").first!["id"]!.int!
        store.add(id: cID, vector: [1, 0])
        let hits = try index.find("retrieval", vectors: store, queryVector: [1, 0])
        #expect(hits.map(\.path).contains("inbox/c.md"))
        #expect(hits.first?.path == "inbox/b.md")   // lexical rank 1 plus vector rank 1 tie → same RRF, lexical doc wins on type boost
    }

    @Test func upsertReplacesAndRemoveCleansUp() throws {
        let index = try KnowledgeIndex.inMemory()
        try index.upsert(doc("x.md", "X", links: ["y.md"]), chunks: Chunker().chunk("first version alpha"))
        try index.upsert(doc("x.md", "X"), chunks: Chunker().chunk("second version beta"))
        #expect(index.chunkCount == 1)
        #expect(try index.find("alpha").isEmpty)
        #expect(try index.find("beta").count == 1)
        #expect(try index.links(from: "x.md").isEmpty)
        try index.remove(path: "x.md")
        #expect(index.documentCount == 0)
        #expect(index.chunkCount == 0)
        #expect(try index.db.query("SELECT COUNT(*) AS n FROM chunks_fts").first?["n"]?.int == 0)
    }

    @Test func embeddingsRoundTrip() throws {
        let index = try KnowledgeIndex.inMemory()
        try index.upsert(doc("x.md", "X"), chunks: Chunker().chunk("some text"))
        let pending = try index.chunksNeedingEmbedding(model: "m")
        #expect(pending.count == 1)
        try index.store(embedding: [0.5, 0.25, 0], chunkID: pending[0].chunkID, model: "m")
        #expect(try index.chunksNeedingEmbedding(model: "m").isEmpty)
        let store = try index.loadVectors(model: "m")
        #expect(store?.count == 1)
        #expect(store?.topK([1, 0.5, 0], k: 1).first?.score ?? 0 > 0.99)
    }

    @Test func rrfAndGrepAndPriors() throws {
        let fused = RRF.fuse([[1, 2, 3], [3, 1]])
        #expect(fused.first?.id == 1)
        #expect(fused.map(\.id) == [1, 3, 2])
        let index = try KnowledgeIndex.inMemory()
        try index.upsert(doc("x.md", "X"), chunks: Chunker().chunk("needle in a haystack 100% sure"))
        #expect(try index.grep("100%").count == 1)
        #expect(try index.grep("nope").isEmpty)
        try index.bumpPrior(key: "host:arxiv.org", project: "research")
        #expect(try index.priors().first?.weight == 1.25)
        try index.setMeta("k", "v")
        #expect(index.meta("k") == "v")
        try index.cacheDecision(hash: "h", backend: "fm", answerJSON: "{}")
        #expect(try index.cachedDecision(hash: "h") == "{}")
        #expect(try index.cachedDecision(hash: "h", maxAge: 0, now: Date().addingTimeInterval(10)) == nil)
    }
}

@Suite struct LinterAndComposerTests {
    @Test func lintFindsPlantedProblems() {
        let pages = [
            LintPage(path: "concepts/orphan.md", title: "Orphan", type: "concept"),
            LintPage(path: "inbox/r1.md", title: "R1", type: "report", links: ["entities/acme.md"], unresolvedLinks: ["Widget Co"], entityMentions: ["Widget Co"], integrated: false),
            LintPage(path: "inbox/r2.md", title: "R2", type: "report", unresolvedLinks: ["Widget Co", "Typo Page"]),
            LintPage(path: "inbox/r3.md", title: "R3", type: "report", entityMentions: ["Widget Co"]),
            LintPage(path: "entities/acme.md", title: "Acme", type: "entity", links: [], staleAfter: Date(timeIntervalSince1970: 0)),
        ]
        let findings = KnowledgeLinter.lint(pages: pages, references: ["inbox/references/abc-paper.pdf"], reportsBySourceKey: [])
        let kinds = Dictionary(grouping: findings, by: \.kind).mapValues(\.count)
        #expect(kinds[.orphan] == 1)
        #expect(findings.first { $0.kind == .orphan }?.path == "concepts/orphan.md")
        #expect(kinds[.missingPage] == 1)
        #expect(findings.first { $0.kind == .missingPage }?.path == "entities/widget-co.md")
        #expect(kinds[.brokenLink] == 1)   // Typo Page
        #expect(kinds[.missingBacklink] == 1)
        #expect(kinds[.notIntegrated] == 1)
        #expect(kinds[.sourceWithoutReport] == 1)
        #expect(kinds[.stale] == 1)
        let page = KnowledgeLinter.render(findings, pageCount: pages.count)
        #expect(page.frontmatter.type == "lint")
        #expect(page.body.contains("## Pages worth creating (1)"))
        #expect(KnowledgeLinter.entityMentions(in: "## Entities\n- **OpenAI** — a lab\n- Sam Altman (person): CEO\n\n## Other\n- not me") == ["OpenAI", "Sam Altman"])
    }

    @Test func composerNumbersCitationsAndReadsThemBack() {
        let hits = (1...3).map { i in KnowledgeHit(chunkID: i, path: "inbox/p\(i).md", title: "P\(i)", type: "report", headingPath: "H", text: "text \(i)", lineStart: 1, lineEnd: 2, page: nil, tsStart: i == 3 ? 125 : nil, resource: nil, score: 1) }
        let p = AnswerComposer.prompt(question: "What is X?", hits: hits)
        #expect(p.citations.count == 3)
        #expect(p.system.contains("[3] P3 › H (inbox/p3.md, 2:05)"))
        #expect(p.system.contains("Answer in the language of the question"))
        let used = AnswerComposer.usedCitations(in: "X is a thing [2]. Also [2] and [9] and [1].", available: p.citations)
        #expect(used.map(\.n) == [2, 1])
        #expect(QueryPlanner.lexicalVariants("What is the capital of France?").contains("capital France"))
    }

    @Test func synthesisPageAndBacklinks() throws {
        let hit = KnowledgeHit(chunkID: 1, path: "concepts/rag.md", title: "RAG", type: "concept", headingPath: "", text: "t", lineStart: 1, lineEnd: 1, page: nil, tsStart: nil, resource: "https://x", score: 1)
        let (slug, doc) = SynthesisWriter.page(question: "How does RAG work?", answer: "It retrieves then generates [1].", citations: [Citation(n: 1, hit: hit)], existingSlugs: ["how-does-rag-work"])
        #expect(slug == "how-does-rag-work-2")
        #expect(doc.frontmatter.type == "synthesis")
        #expect(doc.frontmatter.sources.first?.id == "concepts/rag.md")
        #expect(doc.body.contains("- [1] [[rag|RAG]]"))
        let serialized = doc.serialize()
        #expect((try? OKFDocument.parse(serialized)) != nil)
        let line = SynthesisWriter.backlinkLine(synthesisSlug: slug, title: "How does RAG work?")
        var body = "# RAG\n\nText.\n"
        body = SynthesisWriter.addBacklink(to: body, line: line)
        #expect(body.hasSuffix("## Mentioned in\n\n\(line)\n"))
        let twice = SynthesisWriter.addBacklink(to: body, line: line)
        #expect(twice == body)
        let more = SynthesisWriter.addBacklink(to: body, line: "- [[other|Other]]")
        #expect(more.contains("\(line)\n- [[other|Other]]"))
        #expect(SynthesisWriter.proposedUpdate(to: "x", proposal: "new facts").contains("## Proposed update ("))
    }
}

struct FakeBackend: MCPBackend {
    func call(tool: String, arguments: JSONValue) async -> MCPToolResult {
        MCPToolResult(text: "\(tool):\(arguments["query"].string ?? "")", structured: .object(["ok": .bool(true)]))
    }
}

@Suite struct MCPHandlerTests {
    @Test func speaksJSONRPC() async {
        let h = MCPHandler(backend: FakeBackend())
        let init_ = await h.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-03-26")])]))
        #expect(init_?["result"]["protocolVersion"].string == "2025-03-26")
        #expect(init_?["result"]["serverInfo"]["name"].string == "mochlet")
        #expect(await h.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])) == nil)
        let list = await h.handle(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/list")]))
        #expect(list?["result"]["tools"].array?.count == MCPTools.catalogue.count)
        let call = await h.handle(.object(["jsonrpc": .string("2.0"), "id": .string("x"), "method": .string("tools/call"), "params": .object(["name": .string("find"), "arguments": .object(["query": .string("q")])])]))
        #expect(call?["result"]["content"][0]["text"].string == "find:q")
        #expect(call?["result"]["isError"].bool == false)
        #expect(call?["result"]["structuredContent"]["ok"].bool == true)
        let bad = await h.handle(.object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("tools/call"), "params": .object(["name": .string("nope")])]))
        #expect(bad?["error"]["code"].int == -32602)
        let unknown = await h.handle(.object(["jsonrpc": .string("2.0"), "id": .number(4), "method": .string("foo")]))
        #expect(unknown?["error"]["code"].int == -32601)
        let batch = await h.handle(.array([.object(["jsonrpc": .string("2.0"), "id": .number(5), "method": .string("ping")]), .object(["jsonrpc": .string("2.0"), "method": .string("notifications/x")])]))
        #expect(batch?.array?.count == 1)
    }
}


@Suite struct KnowledgeBundleTests {
    func temporaryBundle() throws -> KnowledgeBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = KnowledgeBundle(root: dir)
        _ = try b.bootstrap()
        return b
    }

    @Test func linksResolveWhenTheTargetAppearsLater() throws {
        let b = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let index = try KnowledgeIndex.inMemory()
        try b.write(text: "---\ntype: concept\ntitle: Alpha\n---\n\n# Alpha\n\nSee [[Beta]].\n", to: "concepts/alpha.md")
        try b.reindex(into: index)
        #expect(try index.allLinks().contains { $0.from == "concepts/alpha.md" && !$0.resolved })
        try b.write(text: "---\ntype: entity\ntitle: Beta\n---\n\n# Beta\n", to: "entities/beta.md")
        let r = try b.reindex(into: index)
        #expect(r.added == 1 && r.updated == 1)
        #expect(try index.allLinks().contains { $0.from == "concepts/alpha.md" && $0.to == "entities/beta.md" && $0.resolved })
        try FileManager.default.removeItem(at: b.url("entities/beta.md"))
        try b.reindex(into: index)
        #expect(try index.allLinks().contains { $0.from == "concepts/alpha.md" && !$0.resolved })
    }

    @Test func textReferencesAreIndexedButNotListed() throws {
        let b = try temporaryBundle()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let index = try KnowledgeIndex.inMemory()
        let (ref, _) = try b.mirror(text: "Raw notes about the Dagger engine and its torque curve.", name: "dagger.txt", into: "inbox")
        try b.reindex(into: index)
        #expect(index.referenceCount == 1)
        #expect(index.documentCount == 1)   // memories/profile.md from bootstrap
        let hits = try index.find("torque curve")
        #expect(hits.first?.path == ref)
        #expect(hits.first?.type == "reference")
        #expect(try index.documents().allSatisfy { $0.type != "reference" })
    }
}


@Suite struct QuestionQueryTests {
    @Test func longQuestionStillHitsThePage() throws {
        let index = try KnowledgeIndex.inMemory()
        let doc = IndexedDocument(path: "inbox/vp.md", type: "report", title: "Vision Pro", description: nil, sha256: "a", mtime: Date(), size: 1, frontmatterYAML: "type: report")
        let chunk = Chunk(ordinal: 0, headingPath: "Vision Pro", text: "Apple released the Vision Pro headset in 2024. It uses the M2 and R1 chips. It costs $3,499.", tokenCount: 30, lineStart: 1, lineEnd: 1)
        try index.upsert(doc, chunks: [chunk])
        #expect(try index.find("How much does the headset cost? Which chips does it use?").first?.path == "inbox/vp.md")
        #expect(QueryPlanner.lexicalVariants("How much does the headset cost?").contains("much headset cost"))
    }

    @Test func lintPagesDoNotReportTheirOwnQuotes() {
        let lint = LintPage(path: "meta/lint-2026-11-06.md", title: "Lint", type: "lint", unresolvedLinks: ["Missing Page"])
        let concept = LintPage(path: "concepts/a.md", title: "A", type: "concept", unresolvedLinks: ["Missing Page"])
        let findings = KnowledgeLinter.lint(pages: [lint, concept])
        #expect(findings.filter { $0.kind == .brokenLink }.map(\.path) == ["concepts/a.md"])
        #expect(!findings.contains { $0.path == lint.path })
    }
}
