import Foundation
import Testing
@testable import MochletCore

private let rss = """
<?xml version="1.0"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel><title>Lab Blog</title><link>https://lab.example</link>
<item><title><![CDATA[Model 3 &amp; friends released]]></title><link>https://lab.example/posts/model-3?utm_source=rss</link><guid isPermaLink="false">post-3</guid>
<description><![CDATA[<p>We release <b>Model 3</b>, our best model.</p>]]></description><pubDate>Thu, 06 Nov 2026 08:00:00 +0000</pubDate><dc:creator>Ada</dc:creator>
<content:encoded><![CDATA[<p>Long body here.</p>]]></content:encoded></item>
<item><title>Hiring: ML engineers</title><link>https://lab.example/jobs</link><pubDate>Wed, 05 Nov 2026 08:00:00 GMT</pubDate></item>
</channel></rss>
"""

private let atom = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Site</title><link rel="alternate" href="https://atom.example/"/>
<entry><title>Agents everywhere</title><id>tag:atom.example,2026:1</id><link rel="alternate" type="text/html" href="https://atom.example/agents"/><link rel="enclosure" href="https://atom.example/a.mp3"/>
<published>2026-11-06T09:30:00Z</published><updated>2026-11-06T10:00:00Z</updated><summary type="html">&lt;p&gt;Agents are here.&lt;/p&gt;</summary><author><name>Grace</name></author></entry>
</feed>
"""

private let rdf = """
<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel rdf:about="https://rdf.example/"><title>RDF Feed</title><link>https://rdf.example/</link></channel>
<item rdf:about="https://rdf.example/one"><title>One</title><link>https://rdf.example/one</link><dc:date>2026-11-05T12:00:00+08:00</dc:date><description>First item</description></item>
</rdf:RDF>
"""

@Test func feedParserReadsRSSAtomAndRDF() {
    let f = FeedParser.parse(rss)!
    #expect(f.title == "Lab Blog" && f.entries.count == 2)
    let e = f.entries[0]
    #expect(e.title == "Model 3 & friends released" && e.link == "https://lab.example/posts/model-3?utm_source=rss" && e.id == "post-3")
    #expect(e.summary == "We release Model 3, our best model." && e.author == "Ada" && e.content.contains("Long body"))
    #expect(e.published == FeedParser.date("2026-11-06T08:00:00Z"))
    let a = FeedParser.parse(atom)!
    #expect(a.title == "Atom Site" && a.link == "https://atom.example/" && a.entries.count == 1)
    #expect(a.entries[0].link == "https://atom.example/agents" && a.entries[0].author == "Grace" && a.entries[0].summary == "Agents are here.")
    #expect(a.entries[0].published == FeedParser.date("2026-11-06T09:30:00Z"))
    let r = FeedParser.parse(rdf)!
    #expect(r.entries.count == 1 && r.entries[0].link == "https://rdf.example/one" && r.entries[0].published != nil)
    #expect(FeedParser.parse("<html><body>no</body></html>") == nil)
    #expect(FeedParser.date("Thu, 06 Nov 2026 08:00:00 +0000") == FeedParser.date("2026-11-06T08:00:00Z"))
    #expect(FeedParser.date("2026-11-06") != nil && FeedParser.date("garbage") == nil)
}

@Test func itemsDedupeByCanonicalURLAndSimhash() throws {
    let a = SignalItem(sourceID: "s1", externalID: "1", url: "https://Lab.example/posts/model-3?utm_source=rss&b=2&a=1", title: "Model 3 released", summary: "Our best model yet")
    let b = SignalItem(sourceID: "s2", externalID: "x", url: "https://lab.example/posts/model-3?a=1&b=2#top", title: "Model 3 released!", summary: "Our best model yet.")
    #expect(a.id == b.id)
    #expect(SimHash.hamming(a.simhash, b.simhash) <= 3)
    let c = SignalItem(sourceID: "s3", externalID: "y", url: "https://other.example/x", title: "Regulators fine a chip maker", summary: "A different story entirely")
    #expect(SimHash.hamming(a.simhash, c.simhash) > 10)
    #expect(SignalText.normalizedTitle("  Model-3: Released! ") == "model 3 released")
    #expect(SignalText.tokens("大模型发布 GPT-5") == ["大模", "模型", "型发", "发布", "gpt", "5"].filter { $0.count >= 2 })
    #expect(SignalText.language("OpenAI 发布了新模型，支持多模态") == "zh" && SignalText.language("OpenAI ships a model") == "en")
    let store = try SignalsStore.inMemory()
    #expect(try store.insert(a) == true)
    #expect(try store.insert(b) == false)
    #expect(try store.insert(c) == true)
    #expect(try store.countItems(status: .new) == 2)
    let hashes = try store.recentSimhashes()
    #expect(hashes.count == 2 && hashes.contains { $0.hash == a.simhash })
}

@Test func rubricParsesAndPrefilterGates() {
    let r = Rubric.parse(Rubric.defaultText)
    #expect(r.threshold(.t1) == 60 && r.threshold(.t2) == 76 && r.weight(.t1_5) == 0.8)
    #expect(r.languages == ["zh", "en"] && r.categoryFloors["opinion"] == 80)
    #expect(r.industryTerms.contains("MCP") && r.industryTerms.contains("大模型"))
    #expect(r.deny.contains("sponsored") && !r.style.isEmpty && r.promptText.contains("What matters"))
    #expect(Prefilter.check(title: "Free webinar on prompts", summary: "", tier: .t1, rubric: r) == .denied("webinar"))
    #expect(Prefilter.check(title: "Quarterly earnings of a retailer", summary: "Sales grew", tier: .t2, rubric: r) == .offTopic)
    #expect(Prefilter.check(title: "Quarterly earnings of a retailer", summary: "Sales grew", tier: .t1, rubric: r) == .pass)
    #expect(Prefilter.check(title: "New LLM beats benchmarks", summary: "", tier: .t2, rubric: r) == .pass)
    #expect(Prefilter.check(title: "Paint drying", summary: "she said the painting was ready", tier: .t2, rubric: r) == .offTopic)
    let custom = Rubric.parse("---\nthresholds: {T2: 50}\nlanguages: [en]\n---\n\n## Prefilter deny\n\n- crypto\n")
    #expect(custom.threshold(.t2) == 50 && custom.threshold(.t1) == 60 && custom.languages == ["en"] && custom.deny == ["crypto"])
    #expect(custom.hash != r.hash)
}

@Test func hotnessAndScheduling() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let m = [Hotness.Mention(sourceID: "a", tier: .t1, at: now.addingTimeInterval(-3600)),
             Hotness.Mention(sourceID: "a", tier: .t1, at: now.addingTimeInterval(-7200)),     // same source counts once
             Hotness.Mention(sourceID: "b", tier: .t2, at: now.addingTimeInterval(-24 * 3600)),
             Hotness.Mention(sourceID: "c", tier: .t1_5, at: now.addingTimeInterval(-72 * 3600))] // outside the window
    let h = Hotness.score(m, now: now)
    #expect(abs(h - (1.0 * pow(0.5, 1.0 / 24) + 0.6 * 0.5)) < 0.01)
    #expect(Hotness.isRising(now: 2.5, sixHoursAgo: 1.2) && !Hotness.isRising(now: 1.1, sixHoursAgo: 1.0) && Hotness.isRising(now: 1.5, sixHoursAgo: 1.0))
    #expect(Hotness.isExciting(hotness: 3.2, firstSeen: now.addingTimeInterval(-1800), now: now) && !Hotness.isExciting(hotness: 3.2, firstSeen: now.addingTimeInterval(-9 * 3600), now: now))
    #expect(SignalScheduling.interval(kind: .rss, yieldPerDay: 0, failures: 0, configured: 0) == 180 * 60)
    #expect(SignalScheduling.interval(kind: .rss, yieldPerDay: 10, failures: 0, configured: 0) == 15 * 60)
    #expect(SignalScheduling.interval(kind: .rss, yieldPerDay: 10, failures: 0, configured: 10) == 10 * 60)
    #expect(SignalScheduling.interval(kind: .xSearch, yieldPerDay: 10, failures: 0, configured: 10) == 30 * 60)
    #expect(SignalScheduling.interval(kind: .rss, yieldPerDay: 1, failures: 3, configured: 0) == 8 * 60 * 60)
    #expect(SignalScheduling.interval(kind: .rss, yieldPerDay: 0, failures: 9, configured: 0) == 12 * 60 * 60)
    let old = now.addingTimeInterval(-400 * 24 * 3600)
    #expect(SignalScheduling.backfill(published: old, firstFetch: true, now: now).take == false)
    #expect(SignalScheduling.backfill(published: now.addingTimeInterval(-3 * 24 * 3600), firstFetch: false, now: now) == (true, true))
    #expect(SignalScheduling.backfill(published: now.addingTimeInterval(-3600), firstFetch: false, now: now) == (true, false))
}

@Test func onlyWebLinksAreSignals() {
    #expect(SignalText.isWebURL("https://openai.com/index/x") && SignalText.isWebURL("http://example.org"))
    #expect(!SignalText.isWebURL("file:///etc/passwd") && !SignalText.isWebURL("javascript:alert(1)") && !SignalText.isWebURL("mailto:a@b.c") && !SignalText.isWebURL("x-apple.systempreferences:"))
    #expect(SignalText.sameSite("https://www.openai.com/a", "https://openai.com/news/rss.xml") && !SignalText.sameSite("https://evil.example/a", "https://openai.com/rss"))
    #expect(WebListExtractor.resolve("file:///tmp/x", base: URL(string: "https://a.b/")) == nil)
    #expect(WebListExtractor.resolve("/p", base: URL(string: "https://a.b/")) == "https://a.b/p")
    let items = ExternalItem.parse(.array([.object(["title": .string("ok"), "url": .string("https://a.b/1")]), .object(["title": .string("bad"), "url": .string("file:///x")])]))
    #expect(items.map(\.title) == ["ok"])
}

@Test func jsonListAndWebListMapping() {
    let json = JSONValue.parse("""
    {"data": {"posts": [{"id": 7, "headline": "GPU prices fall", "slug": "gpu", "ts": 1762400000, "excerpt": "<b>Down</b> 20%"},
                        {"id": 8, "title": "", "slug": "empty"}]}}
    """)!
    let c = JSONListMapper.Config(url: "https://api.example/posts", itemsPath: "data.posts", titlePaths: ["headline", "title"], urlTemplate: "https://site.example/p/{raw:slug}", summaryPath: "excerpt", idPath: "id", publishedAtPath: "ts", publishedAtUnit: "s")
    let items = JSONListMapper.items(json, config: c)
    #expect(items.count == 1)
    #expect(items.first?.title == "GPU prices fall")
    #expect(items.first?.url == "https://site.example/p/gpu")
    #expect(items.first?.id == "7")
    #expect(items.first?.summary == "Down 20%")
    #expect(items[0].published == Date(timeIntervalSince1970: 1_762_400_000))
    let fromConfig = JSONListMapper.Config(["url": .string("u"), "itemsPath": .string("items"), "titlePaths": .array([.string("t")]), "urlPath": .string("u")])
    #expect(fromConfig?.titlePaths == ["t"] && fromConfig?.urlPath == "u")

    let html = """
    <html><head><title>News</title><link rel="alternate" type="application/rss+xml" title="All posts" href="/feed.xml"></head>
    <body><script>var x = "<li class='post'>fake</li>";</script><!-- <li class="post">comment</li> -->
    <ul id="list">
      <li class="post"><h2><a href="/p/1">First story about agents and models</a></h2><time datetime="2026-11-06T01:00:00Z">today</time><p class="sum">Summary one</p></li>
      <li class="post"><a href="https://news.example/p/2">Second story about chips &amp; power</a></li>
      <li class="post"><a href="/p/3">Third story about a funding round</a></li>
      <li class="post"><a href="/p/4">Fourth story about regulation of models</a></li>
      <li class="post"><a href="/p/5">Fifth story about a benchmark result</a></li>
      <li class="ad"><a href="/ad">Buy</a></li>
    </ul><a href="/about">About us and our mission here</a></body></html>
    """
    let base = URL(string: "https://news.example/")!
    let config = WebListExtractor.Config(url: base.absoluteString, itemSelector: "ul#list > li.post", linkSelector: "a", summarySelector: "p.sum", publishedAtSelector: "time")
    let web = WebListExtractor.items(html: html, baseURL: base, config: config)
    #expect(web.count == 5)
    #expect(web[0].title == "First story about agents and models" && web[0].url == "https://news.example/p/1" && web[0].summary == "Summary one" && web[0].published != nil)
    #expect(web[1].title == "Second story about chips & power" && web[1].url == "https://news.example/p/2")
    let doc = HTMLDocument.parse(html)
    #expect(doc.select("li.post a[href]").count == 5 && doc.select("li[class=ad]").count == 1 && doc.first("ul#list")?.children.count == 6)
    let guess = SourceDetector.guess(html: html, baseURL: base)
    #expect(guess.feeds.first?.url == "https://news.example/feed.xml" && guess.feeds.first?.title == "All posts")
    #expect(guess.list?.itemSelector == "li.post" && guess.list?.count == 5 && guess.list?.samples.first == "First story about agents and models")
    #expect(SourceDetector.looksLikeFeed(contentType: "application/rss+xml", body: Data(rss.utf8)) && !SourceDetector.looksLikeFeed(contentType: "text/html", body: Data(html.utf8)))
}

@Test func digestSelectionAndMarkdown() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func c(_ i: Int, event: String, source: String, score: Double, hot: Double, sources: Int = 1) -> DigestComposer.Candidate {
        DigestComposer.Candidate(id: "i\(i)", eventID: event, sourceID: source, sourceName: source.uppercased(), tier: .t1, url: "https://x.example/\(i)", titleZH: "标题\(i)", titleEN: "Title \(i)",
                                 summaryZH: "摘要\(i)", summaryEN: "Summary \(i)", reason: "because", score: score, hotness: hot, rising: hot > 2, isNew: true, eventSources: sources, publishedAt: now)
    }
    var cands: [DigestComposer.Candidate] = []
    cands.append(c(1, event: "e1", source: "a", score: 90, hot: 3.1, sources: 3))
    cands.append(c(2, event: "e1", source: "b", score: 70, hot: 3.1, sources: 3))      // same event, lower score → dropped
    cands.append(c(3, event: "e2", source: "a", score: 80, hot: 1.0))
    cands.append(c(4, event: "e3", source: "a", score: 85, hot: 1.0))                   // third from source a → brief
    cands.append(c(5, event: "e4", source: "c", score: 60, hot: 0.5))
    cands.append(c(6, event: "e5", source: "d", score: 95, hot: 2.5, sources: 2))      // shown before with 2 sources → skipped
    let sel = DigestComposer.select(cands, recentlyShown: ["e5": 2], maxSelected: 3, maxBriefs: 5, perSource: 2)
    #expect(sel.hot.map(\.id) == ["i1"])
    #expect(sel.selected.map(\.id) == ["i4", "i5"])   // i3 is the third from source a → a brief
    #expect(sel.briefs.map(\.id) == ["i3"])
    #expect(!sel.all.contains { $0.id == "i2" || $0.id == "i6" })
    let md = DigestComposer.markdown(date: now, selection: sel, overview: "An overview.", languages: ["zh", "en"])
    #expect(md.hasPrefix("# AI 信号 · ") && md.contains("## 热点 / Hot") && md.contains("### 标题1 ↑ ×3 [^e1]") && md.contains("_Title 1_") && md.contains("[^e1]: A · <https://x.example/1>"))
    #expect(md.contains("## 简讯 / Briefs") && md.contains("An overview."))
    let page = DigestComposer.page(date: now, selection: sel, overview: nil, languages: ["en"], rubricHash: "abcdef123456789", itemsSeen: 40, window: (now.addingTimeInterval(-86400), now), by: "mochlet/2.0", now: now)
    #expect(page.frontmatter.type == "digest" && page.frontmatter.title?.hasPrefix("AI signals ") == true && page.frontmatter.sources.count == sel.all.count)
    #expect(page.frontmatter.mochlet?["hot"] == .int(1) && page.frontmatter.mochlet?["rubric_hash"] == .string("abcdef123456"))
    #expect(page.body.contains("## Hot") && !page.body.contains("热点"))
    let empty = DigestComposer.markdown(date: now, selection: DigestComposer.Selection(hot: [], selected: [], briefs: []), overview: nil, languages: ["en"])
    #expect(empty.contains("Nothing worth a line today."))
}

@Test func aihotImportAndDefaults() throws {
    let json = """
    {"version": 1, "sources": [
      {"id": "rss-openai-news", "name": "OpenAI News", "kind": "rss", "config": {"feedUrl": "https://openai.com/news/rss.xml", "_aihot": {"initialBackfillLimit": 8}}, "tier": "T1", "owner_entity_id": "openai", "participation_mode": "editorial", "interval_minutes": 120, "tags": ["官方"], "site_fulltext": false},
      {"id": "mp-foo", "name": "公众号", "kind": "mp_account", "config": {"biz": "x"}, "tier": "T2", "participation_mode": "isolated", "interval_minutes": 60, "tags": []},
      {"id": "x-ai", "name": "X AI", "kind": "x_search", "config": {"query": "AI lang:zh", "searchType": "Latest"}, "tier": "T2", "participation_mode": "hot_signal", "interval_minutes": 30, "tags": []},
      {"id": "future", "name": "Unknown", "kind": "telepathy", "config": {}, "tier": "T2"}
    ]}
    """
    let incoming = try AIHOTImport.parse(Data(json.utf8))
    #expect(incoming.count == 4)
    #expect(incoming[0].kind == .rss && incoming[0].url == "https://openai.com/news/rss.xml" && incoming[0].tier == .t1 && incoming[0].ownerEntityID == "openai")
    #expect(incoming[1].kind == .mpAccount && incoming[1].enabled == false)
    #expect(incoming[2].kind == .xSearch && incoming[2].participationMode == .hotSignal && incoming[2].enabled)
    #expect(incoming[3].kind == .external && incoming[3].enabled == false)
    var mine = DefaultSources.make()
    mine[0].enabled = false
    let (merged, report) = AIHOTImport.merge(incoming, into: mine)
    #expect(report.added.sorted() == ["future", "mp-foo", "x-ai"] && report.updated == ["rss-openai-news"] && report.disabled.sorted() == ["future", "mp-foo"])
    let openai = merged.first { $0.id == "rss-openai-news" }
    #expect(openai?.enabled == false && openai?.intervalMinutes == 120 && openai?.tags == ["官方"])   // the user's switch is kept, AIHOT's settings taken
    #expect(AIHOTImport.merge(incoming, into: merged).report.skipped.count == 4)
    let data = try JSONEncoder().encode(SourcesFile(sources: merged))
    let round = try JSONDecoder().decode(SourcesFile.self, from: data)
    #expect(round.sources == merged)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"participation_mode\"") && text.contains("\"interval_minutes\"") && text.contains("\"feedUrl\""))
    let aihot = SignalSource(id: "my-aihot", name: "AIHOT", kind: .aihot, config: ["baseUrl": .string("https://aihot.example"), "feeds": .array([.string("/feed/daily.xml")]), "trustRemoteScores": .bool(true)])
    #expect(AIHOTImport.feedURLs(aihot).map(\.absoluteString) == ["https://aihot.example/feed/daily.xml"] && AIHOTImport.trustsRemoteScores(aihot))
    #expect(Set(DefaultSources.make().map(\.id)).count == DefaultSources.make().count)
    let ext = ExternalItem.parse(JSONValue.parse("{\"items\": [{\"title\": \"T\", \"url\": \"https://e.example/1\", \"published_at\": \"2026-11-06T00:00:00Z\"}, {\"title\": \"\", \"url\": \"x\"}]}")!)
    #expect(ext.count == 1 && ext[0].publishedAt == "2026-11-06T00:00:00Z")
}

@Test func storeEventsDigestsAndUsage() throws {
    let store = try SignalsStore.inMemory()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let a = SignalItem(sourceID: "s1", externalID: "1", url: "https://a.example/1", title: "A story", discoveredAt: now)
    let b = SignalItem(sourceID: "s2", externalID: "2", url: "https://b.example/2", title: "A story too", discoveredAt: now)
    try store.insert(a)
    try store.insert(b)
    try store.saveScore(a.id, SignalScore(score1: 80, score2: 70, category: "release", tags: ["x", "y"], mainEntity: "Lab", reasons: "r", rubricHash: "h"))
    #expect(try store.score(a.id)?.combined == 75 && (try store.score(a.id)?.tags) == ["x", "y"])
    try store.saveWriting(a.id, SignalWriting(titleZH: "甲", titleEN: "A", summaryZH: "乙", summaryEN: "B", reason: "c"))
    #expect(try store.writing(a.id)?.titleEN == "A")
    try store.saveEmbedding(a.id, [0.1, 0.2, 0.3])
    #expect(try store.embeddings(itemIDs: [a.id, b.id])[a.id] == [0.1, 0.2, 0.3])
    try store.setEvent(a.id, "ev1")
    try store.setEvent(b.id, "ev1")
    try store.saveEvent(SignalEvent(id: "ev1", title: "A story", firstSeen: now, lastSeen: now, hotness: 1.6, sourceCount: 2, topItemID: a.id))
    #expect(try store.mentions(eventID: "ev1", tiers: ["s1": .t1, "s2": .t2]).count == 2)
    try store.link(a.id, b.id, relation: .sameOccurrence, confidence: 0.9)
    #expect(try store.linkChecked(b.id, a.id))
    try store.recordHotness("ev1", 1.0, at: now.addingTimeInterval(-7 * 3600))
    try store.recordHotness("ev1", 1.6, at: now)
    #expect(try store.hotness("ev1", before: now.addingTimeInterval(-6 * 3600)) == 1.0)
    #expect(try store.events(since: now.addingTimeInterval(-60)).first?.id == "ev1")
    try store.saveDigest(day: "2026-11-06", path: "signals/2026-11-06.md", items: 3, hot: 1, events: ["ev1:2", "ev2"], at: now)
    #expect(try store.latestDigest()?.path == "signals/2026-11-06.md" && (try store.recentlyShown()) == ["ev1": 2, "ev2": 1])
    // Recomposing a day leaves that day's own digest out, so its picks are not treated as already shown.
    try store.saveDigest(day: "2026-11-05", path: "signals/2026-11-05.md", items: 1, hot: 0, events: ["ev3"], at: now.addingTimeInterval(-86400))
    #expect(try store.recentlyShown() == ["ev1": 2, "ev2": 1, "ev3": 1])
    #expect(try store.recentlyShown(excludingDay: "2026-11-06") == ["ev3": 1])
    try store.bump(day: "2026-11-06", task: "score")
    try store.bump(day: "2026-11-06", task: "score", by: 2)
    #expect(try store.usage(day: "2026-11-06", task: "score") == 3 && (try store.usageToday(day: "2026-11-06")) == ["score": 3])
    var st = try store.sourceState("s1")
    st.etag = "W/\"1\""
    st.failures = 2
    st.fetched = 1
    try store.saveSourceState("s1", st)
    #expect(try store.sourceState("s1").etag == "W/\"1\"" && (try store.sourceState("s1").failures) == 2)
    try store.setStatus(a.id, .accepted)
    #expect(abs((try store.yieldPerDay("s1", now: now)) - 1.0 / 7) < 0.001)
    try store.prune(olderThan: 60, now: now.addingTimeInterval(61 * 24 * 3600))
    #expect(try store.countItems(status: .accepted) == 0 && (try store.event("ev1")) == nil)
}
