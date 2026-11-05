import Foundation
import MochletCore
import MochletServices
import os

private let logger = Logger(subsystem: "com.ilexpwh.Mochlet", category: "signals")

/// The signals pipeline over `signals.sqlite`: new items → prefilter → body → two scores → writing →
/// embedding → event clustering → hotness. Fetching happens outside (the controller pulls sources in
/// parallel and hands the items in); the brain is passed per call so the engine holds no app state.
actor SignalsEngine {
    struct RunReport: Sendable {
        var fetched = 0
        var new = 0
        var prefiltered = 0
        var scored = 0
        var accepted = 0
        var written = 0
        var events = 0
        var exciting: [SignalEvent] = []
        var errors: [String] = []
        var budgetHit = false
        var summary: String {
            var parts = ["\(new) new", "\(prefiltered) filtered", "\(scored) scored", "\(accepted) accepted", "\(written) written"]
            if budgetHit { parts.append("budget reached") }
            if !errors.isEmpty { parts.append("\(errors.count) errors") }
            return parts.joined(separator: " · ")
        }
    }

    struct Status: Sendable {
        var itemsToday = 0
        var acceptedToday = 0
        var pending = 0
        var hot: [SignalEvent] = []
        var latestDigest: (day: String, path: String, items: Int, hot: Int)?
        var usage: [String: Int] = [:]
        var states: [String: SignalsStore.SourceState] = [:]
        var usedCalls: Int { usage.values.reduce(0, +) }
    }

    let store: SignalsStore
    private(set) var rubric: Rubric
    private(set) var sources: [SignalSource]
    private let embedding = AppleContextualEmbedding()
    private var embeddingAvailable: Bool?
    var onStage: (@Sendable (String) -> Void)?

    static let stopWords: Set<String> = ["the", "a", "an", "of", "to", "for", "with", "and", "in", "on", "at", "is", "its", "it", "as", "by", "from", "how", "can", "both",
                                         "that", "this", "new", "now", "s", "vs", "into", "up", "out", "over", "than", "more", "what", "why", "your", "you", "we", "our",
                                         "introducing", "announcing", "launches", "launch", "releases", "release", "released", "unveils", "ships", "brings", "available",
                                         "的", "了", "和", "与", "在", "是", "为", "及", "等", "或", "发布", "推出", "宣布", "上线", "正式", "全新"]
    static let scoreBatch = 12
    static let firstFetchCap = 30
    /// Score batches per run: the rest waits for the next tick, so one run never monopolises the brain.
    static let scoreBatchesPerRun = 5
    static let writeBatch = 10
    static let pairBatch = 12

    init(storePath: String, rubric: Rubric, sources: [SignalSource]) throws {
        store = try SignalsStore(path: storePath)
        self.rubric = rubric
        self.sources = sources
    }

    func update(sources: [SignalSource]) { self.sources = sources }
    func update(rubric: Rubric) { self.rubric = rubric }
    func setStageHandler(_ h: @escaping @Sendable (String) -> Void) { onStage = h }
    private func stage(_ s: String) { onStage?(s) }

    private var tiers: [String: SourceTier] { Dictionary(sources.map { ($0.id, $0.tier) }, uniquingKeysWith: { a, _ in a }) }
    private func source(_ id: String) -> SignalSource? { sources.first { $0.id == id } }

    static func day(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // MARK: - Scheduling and intake

    func sourceState(_ id: String) -> SignalsStore.SourceState { (try? store.sourceState(id)) ?? SignalsStore.SourceState() }

    /// Enabled sources whose next fetch is due (or all fetchable ones when forced).
    func due(now: Date = Date(), force: Bool = false) -> [SignalSource] {
        sources.filter { s in
            guard s.enabled, s.kind != .external, s.kind != .mpAccount else { return false }
            if force { return true }
            let st = sourceState(s.id)
            return st.nextFetch.map { $0 <= now } ?? true
        }
    }

    /// Records what a fetch brought (or how it failed) and plans the next one.
    @discardableResult
    func record(_ pulled: SourceFetcher.Pulled?, for source: SignalSource, error: String?, now: Date = Date()) -> Int {
        var st = sourceState(source.id)
        let firstFetch = st.lastFetch == nil
        var created = 0
        if let pulled {
            st.etag = pulled.etag ?? st.etag
            st.lastModified = pulled.lastModified ?? st.lastModified
            st.failures = 0
            st.lastError = nil
            if !pulled.notModified {
                var recent = (try? store.recentSimhashes(now: now)) ?? []
                var incoming = pulled.items
                if firstFetch, incoming.count > Self.firstFetchCap {
                    incoming = Array(incoming.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.prefix(Self.firstFetchCap))
                }
                for var it in incoming {
                    let rule = SignalScheduling.backfill(published: it.publishedAt, firstFetch: firstFetch, now: now)
                    guard rule.take else { continue }
                    it.backfill = rule.backfill
                    if it.title.isEmpty || !SignalText.isWebURL(it.url) { continue }
                    if recent.contains(where: { $0.id != it.id && SimHash.hamming($0.hash, it.simhash) <= 3 }) { continue }
                    if (try? store.insert(it)) == true { created += 1; st.fetched += 1; recent.append((it.id, it.simhash)) }
                }
            }
            try? store.logFetch(source.id, status: pulled.notModified ? "not-modified" : "ok", items: created, error: nil, at: now)
        } else {
            st.failures += 1
            st.lastError = error
            try? store.logFetch(source.id, status: "failed", items: 0, error: error, at: now)
        }
        st.lastFetch = now
        let yield = (try? store.yieldPerDay(source.id, now: now)) ?? 0
        let interval = SignalScheduling.interval(kind: source.kind, yieldPerDay: yield, failures: st.failures, configured: source.intervalMinutes,
                                                 hotSignal: source.participationMode == .hotSignal)
        st.nextFetch = now.addingTimeInterval(interval)
        try? store.saveSourceState(source.id, st)
        return created
    }

    /// Items pushed in (the endpoint or the watch folder) for an external source.
    func ingest(_ items: [ExternalItem], sourceID: String, now: Date = Date()) -> Int {
        var created = 0
        var recent = (try? store.recentSimhashes(now: now)) ?? []
        for e in items {
            guard !e.title.isEmpty, SignalText.isWebURL(e.url) else { continue }
            let it = SignalItem(sourceID: sourceID, externalID: e.externalID ?? e.url, url: e.url, title: e.title, summary: e.summary ?? "",
                                publishedAt: e.publishedAt.flatMap(FeedParser.date), discoveredAt: now)
            if recent.contains(where: { SimHash.hamming($0.hash, it.simhash) <= 3 }) { continue }
            if (try? store.insert(it)) == true { created += 1; recent.append((it.id, it.simhash)) }
        }
        if created > 0 { try? store.logFetch(sourceID, status: "push", items: created, error: nil, at: now) }
        return created
    }

    // MARK: - The pipeline

    /// Everything still `new`: filtered, scored, written, clustered. `budget` caps brain calls per day.
    func process(brain: LLMClient?, budget: Int, now: Date = Date()) async -> RunReport {
        var report = RunReport()
        let day = Self.day(now)
        let tiers = tiers
        func used() -> Int { ((try? store.usageToday(day: day)) ?? [:]).values.reduce(0, +) }
        func spend(_ task: String, _ n: Int = 1) { try? store.bump(day: day, task: task, by: n) }

        guard var fresh = try? store.items(status: .new, limit: 400) else { return report }
        report.new = fresh.count

        // 1. Prefilter (no model): deny list, T2 needs an industry term; stale leftovers go.
        stage("filtering")
        fresh = fresh.filter { it in
            let tier = tiers[it.sourceID] ?? .t2
            if it.backfill || now.timeIntervalSince(it.publishedAt ?? it.discoveredAt) > 3 * 86_400 { try? store.setStatus(it.id, .prefiltered); report.prefiltered += 1; return false }
            switch Prefilter.check(title: it.title, summary: it.summary, tier: tier, rubric: rubric) {
            case .pass: return true
            case .denied, .offTopic:
                try? store.setStatus(it.id, .prefiltered)
                report.prefiltered += 1
                return false
            }
        }

        // Curated AIHOT feeds are trusted as scored.
        for it in fresh where source(it.sourceID)?.kind == .aihot && AIHOTImport.trustsRemoteScores(source(it.sourceID)!) {
            try? store.saveScore(it.id, SignalScore(score1: 80, score2: 80, category: "aihot", tags: [], reasons: "accepted by the AIHOT instance", rubricHash: rubric.hash), at: now)
            try? store.setStatus(it.id, .accepted)
            report.accepted += 1
        }
        fresh.removeAll { source($0.sourceID)?.kind == .aihot && AIHOTImport.trustsRemoteScores(source($0.sourceID)!) }

        guard let brain else {
            // No brain: nothing can be scored; the items wait (and expire after three days).
            if !fresh.isEmpty { report.errors.append("No brain is configured (Settings → Chat); \(fresh.count) items wait.") }
            return await finish(report, brain: nil, budget: budget, day: day, now: now)
        }

        // 2. Body for T1 / T1.5 items whose feed gave only a blurb.
        var bodies = 0
        for it in fresh where it.body.isEmpty && it.summary.count < 200 && (tiers[it.sourceID] ?? .t2) != .t2 && bodies < 12 {
            guard SignalText.isWebURL(it.url), let u = URL(string: it.url) else { continue }
            stage("reading \(u.host ?? "page")")
            // Only a page on the source's own site inherits the trust the user gave that source (its feed host may
            // resolve privately on this network); every other link a feed hands us is fetched as a public URL.
            let src = source(it.sourceID)
            let site = src.flatMap { $0.kind == .external ? nil : $0.url }
            let ownSite = SignalText.sameSite(it.url, site)
            if let b = try? await SourceFetcher.body(for: u, publicOnly: !ownSite, site: ownSite ? site : nil), !b.isEmpty { try? store.setBody(it.id, b); bodies += 1 }
        }
        if bodies > 0, let again = try? store.items(status: .new, limit: 400) {
            let ids = Set(fresh.map(\.id))
            fresh = again.filter { ids.contains($0.id) }
        }

        // 3. Two independent scores per batch; T2 waits when the budget is nearly spent.
        var toScore = fresh.sorted { (tiers[$0.sourceID] ?? .t2).weight > (tiers[$1.sourceID] ?? .t2).weight }
        if budget - used() < budget / 4 {
            toScore.removeAll { (tiers[$0.sourceID] ?? .t2) == .t2 }
        }
        var accepted: [SignalItem] = []
        for batch in toScore.chunked(Self.scoreBatch).prefix(Self.scoreBatchesPerRun) {
            guard used() + 2 <= budget else { report.budgetHit = true; break }
            stage("scoring \(batch.count) items")
            let rows = batch.enumerated().map { i, it in (id: "\(i + 1)", source: source(it.sourceID)?.name ?? it.sourceID, tier: tiers[it.sourceID] ?? .t2, text: it.text()) }
            do {
                let first = try await brain.structured(SignalPrompts.ScoreBatch.self, system: SignalPrompts.scoreSystem,
                                                       user: SignalPrompts.scoreUser(rubric: rubric, items: rows, shuffled: false), schema: SignalPrompts.scoreSchema())
                spend("score")
                let second = try await brain.structured(SignalPrompts.ScoreBatch.self, system: SignalPrompts.scoreSystem,
                                                        user: SignalPrompts.scoreUser(rubric: rubric, items: rows.reversed(), shuffled: true), schema: SignalPrompts.scoreSchema())
                spend("score")
                let a = Dictionary(first.scores.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                let b = Dictionary(second.scores.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                for (i, it) in batch.enumerated() {
                    let key = "\(i + 1)"
                    guard let r1 = a[key] else { continue }
                    let r2 = b[key]
                    let s1 = min(100, max(0, r1.score)), s2 = min(100, max(0, r2?.score ?? r1.score))
                    let score = SignalScore(score1: s1, score2: s2, category: r1.category, tags: r1.tags, mainEntity: r1.mainEntity, reasons: r1.reasons, rubricHash: rubric.hash)
                    try? store.saveScore(it.id, score, at: now)
                    report.scored += 1
                    let tier = tiers[it.sourceID] ?? .t2
                    let floor = rubric.categoryFloors[r1.category.lowercased()] ?? 0
                    let ok = s1 + s2 >= 2 * rubric.threshold(tier) && score.combined >= floor
                    try? store.setStatus(it.id, ok ? .accepted : .rejected)
                    if ok { accepted.append(it); report.accepted += 1 }
                }
            } catch {
                report.errors.append("scoring: " + ErrorText.describe(error))
                logger.error("scoring failed: \(ErrorText.describe(error), privacy: .private)")
                break
            }
        }
        return await finish(report, brain: brain, budget: budget, day: day, now: now)
    }

    /// Writing, embedding and clustering for everything accepted, then the events' hotness.
    private func finish(_ input: RunReport, brain: LLMClient?, budget: Int, day: String, now: Date) async -> RunReport {
        var report = input
        func used() -> Int { ((try? store.usageToday(day: day)) ?? [:]).values.reduce(0, +) }
        func spend(_ task: String, _ n: Int = 1) { try? store.bump(day: day, task: task, by: n) }
        let tiers = tiers
        var touched = Set<String>()

        // 4. The bilingual writing.
        let pending = (try? store.items(status: .accepted, limit: 200)) ?? []
        if let brain {
            for batch in pending.chunked(Self.writeBatch) {
                guard used() < budget else { report.budgetHit = true; break }
                stage("writing \(batch.count) items")
                let rows = batch.enumerated().map { i, it in (id: "\(i + 1)", source: source(it.sourceID)?.name ?? it.sourceID, text: it.text(limit: 3000)) }
                do {
                    let out = try await brain.structured(SignalPrompts.WriteBatch.self, system: SignalPrompts.writeSystem,
                                                         user: SignalPrompts.writeUser(style: rubric.style, items: rows), schema: SignalPrompts.writeSchema())
                    spend("write")
                    let byID = Dictionary(out.items.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
                    for (i, it) in batch.enumerated() {
                        guard let w = byID["\(i + 1)"] else { continue }
                        try? store.saveWriting(it.id, SignalWriting(titleZH: w.titleZH, titleEN: w.titleEN, summaryZH: w.summaryZH, summaryEN: w.summaryEN, reason: w.reason))
                        try? store.setStatus(it.id, .written)
                        report.written += 1
                    }
                } catch {
                    report.errors.append("writing: " + ErrorText.describe(error))
                    break
                }
            }
        }

        // 5. Embeddings and events for items written but not yet placed.
        let grouped = await group(brain: brain, budget: budget, day: day, now: now)
        touched.formUnion(grouped.touched)
        report.errors += grouped.errors

        // 6. Hotness of the events touched now (and of the recent ones, hourly from the controller).
        for id in touched { if let e = refreshEvent(id, tiers: tiers, now: now) { report.events += 1; if Hotness.isExciting(hotness: e.hotness, firstSeen: e.firstSeen, now: now) { report.exciting.append(e) } } }
        return report
    }

    /// Unit vectors centred on the mean of the set (the common part removed).
    static func centre(_ vectors: [String: [Float]]) -> [String: [Float]] {
        guard let dim = vectors.values.first?.count, vectors.count >= 2 else { return vectors.mapValues(TranscriptBuilder.normalized) }
        var mean = [Float](repeating: 0, count: dim)
        var n: Float = 0
        for v in vectors.values where v.count == dim { for k in 0..<dim { mean[k] += v[k] }; n += 1 }
        guard n > 0 else { return vectors }
        for k in 0..<dim { mean[k] /= n }
        return vectors.mapValues { v in
            guard v.count == dim else { return TranscriptBuilder.normalized(v) }
            var c = v
            for k in 0..<dim { c[k] -= mean[k] }
            return TranscriptBuilder.normalized(c)
        }
    }

    /// Events for every written item not yet placed: candidates by title overlap, shared main entity
    /// or centred embeddings; the brain confirms pairs; a clear title overlap merges on its own.
    func group(brain: LLMClient?, budget: Int, day: String, now: Date) async -> (touched: Set<String>, errors: [String]) {
        var touched = Set<String>()
        var errors: [String] = []
        func used() -> Int { ((try? store.usageToday(day: day)) ?? [:]).values.reduce(0, +) }
        func spend(_ task: String, _ n: Int = 1) { try? store.bump(day: day, task: task, by: n) }
        let placed = ((try? store.items(since: now.addingTimeInterval(-3 * 86_400), statuses: [.written])) ?? []).filter { $0.eventID == nil }
        if !placed.isEmpty {
            stage("grouping \(placed.count) items")
            let window = (try? store.items(since: now.addingTimeInterval(-14 * 86_400), statuses: [.written])) ?? []
            var vectors = (try? store.embeddings(itemIDs: window.map(\.id))) ?? [:]
            for it in placed where vectors[it.id] == nil {
                if let v = await embed(it) { vectors[it.id] = v; try? store.saveEmbedding(it.id, v) }
            }
            let writings: [String: SignalWriting] = Dictionary(window.compactMap { it in (try? store.writing(it.id)).map { (it.id, $0) } }, uniquingKeysWith: { a, _ in a })
            func writing(_ id: String) -> SignalWriting? { writings[id] }
            func tokens(_ it: SignalItem) -> [String] {
                let w = writing(it.id)
                let text = (w?.titleEN.isEmpty == false ? w!.titleEN : it.title) + " " + (w?.titleZH ?? "")
                return SignalText.tokens(text).filter { !Self.stopWords.contains($0) }
            }
            let entities: [String: String] = Dictionary(window.compactMap { it in (try? store.score(it.id))?.mainEntity.flatMap { e in e.isEmpty ? nil : (it.id, e.lowercased()) } }, uniquingKeysWith: { a, _ in a })
            var assigned: [String: String] = Dictionary(window.compactMap { it in it.eventID.map { (it.id, $0) } }, uniquingKeysWith: { a, _ in a })
            // Contextual embeddings share a large common component (every AI post looks alike), so vectors are
            // centred on the window's mean before cosine, as the diarizer does with voices; the raw cosine
            // would put every post of one lab into one event.
            let centred = Self.centre(vectors)
            for it in placed {
                // Candidates: close centred vectors or overlapping titles among already placed items. A title
                // overlap alone can merge without the brain; a vector alone never does.
                var scored: [(SignalItem, Double, Double)] = []   // item, centred cosine, title overlap
                let mine = Set(tokens(it))
                for other in window where other.id != it.id && assigned[other.id] != nil {
                    var sim = 0.0
                    if let a = centred[it.id], let b = centred[other.id], a.count == b.count { sim = Double(TranscriptBuilder.dot(a, b)) }
                    let theirs = Set(tokens(other))
                    let shared = mine.intersection(theirs).count
                    // Overlap of the shorter title ("Introducing GPT-6 Cyber" sits inside a longer headline).
                    let overlap = shared == 0 ? 0 : Double(shared) / Double(max(1, min(mine.count, theirs.count)))
                    let sameEntity = entities[it.id] != nil && entities[it.id] == entities[other.id]
                    if sim >= 0.55 || (overlap >= 0.5 && shared >= 2) || (sameEntity && (overlap >= 0.25 || sim >= 0.35)) { scored.append((other, sim, overlap)) }
                }
                scored.sort { max($0.1, $0.2) > max($1.1, $1.2) }
                var event: String?
                let strong = scored.first { c in c.2 >= 0.9 && Set(tokens(c.0)).intersection(mine).count >= 4 }
                if let strong { event = assigned[strong.0.id] }
                else if let brain, !scored.isEmpty, used() < budget {
                    let unchecked = scored.prefix(4).filter { !((try? store.linkChecked(it.id, $0.0.id)) ?? false) }
                    if !unchecked.isEmpty {
                        let text = { (x: SignalItem) -> String in
                            let w = writing(x.id)
                            return String(((w?.titleEN ?? x.title) + "\n" + (w?.summaryEN ?? x.summary)).prefix(500))
                        }
                        do {
                            let out = try await brain.structured(SignalPrompts.PairBatch.self, system: SignalPrompts.pairSystem,
                                                                 user: SignalPrompts.pairUser(unchecked.map { (a: (id: "a", text: text(it)), b: (id: $0.0.id.prefix(8).description, text: text($0.0))) }),
                                                                 schema: SignalPrompts.pairSchema())
                            spend("pair")
                            for p in out.pairs {
                                guard let other = unchecked.first(where: { $0.0.id.hasPrefix(p.b) })?.0 else { continue }
                                let rel = EventRelation(rawValue: p.relation.uppercased()) ?? .unrelated
                                try? store.link(it.id, other.id, relation: rel, confidence: p.confidence)
                                if event == nil, rel.joins, p.confidence >= 0.7 { event = assigned[other.id] }
                            }
                        } catch {
                            errors.append("pairing: " + ErrorText.describe(error))
                        }
                    }
                } else if brain == nil, let best = scored.first, best.2 >= 0.7 {
                    event = assigned[best.0.id]
                }
                let id = event ?? String(it.id.prefix(16))
                assigned[it.id] = id
                try? store.setEvent(it.id, id)
                touched.insert(id)
            }
        }

        return (touched, errors)
    }

    /// Forgets every event of the last 14 days and groups again (after a rubric or clustering change).
    func recluster(brain: LLMClient?, budget: Int, now: Date = Date()) async -> Int {
        let since = now.addingTimeInterval(-14 * 86_400)
        _ = try? store.db.run("UPDATE items SET event_id = NULL WHERE status = 'written' AND discovered >= ?", [.double(since.timeIntervalSince1970)])
        _ = try? store.db.run("DELETE FROM events", [])
        _ = try? store.db.run("DELETE FROM event_links", [])
        _ = try? store.db.run("DELETE FROM hotness_history", [])
        let g = await group(brain: brain, budget: budget, day: Self.day(now), now: now)
        let tiers = tiers
        for id in g.touched { refreshEvent(id, tiers: tiers, now: now) }
        return g.touched.count
    }

    private func embed(_ it: SignalItem) async -> [Float]? {
        let w = try? store.writing(it.id)
        let text = ((w?.titleEN).flatMap { $0.isEmpty ? nil : $0 } ?? it.title) + " " + (w?.summaryEN ?? it.summary).prefix(400)
        if embeddingAvailable == nil { embeddingAvailable = AppleContextualEmbedding.assetsAvailable(for: text) }
        guard embeddingAvailable == true else { return nil }
        return (try? await embedding.embed([text]))?.first
    }

    /// Hotness, rising, new, source count and title of one event, saved with a history point.
    @discardableResult
    func refreshEvent(_ id: String, tiers: [String: SourceTier]? = nil, now: Date = Date()) -> SignalEvent? {
        let tiers = tiers ?? self.tiers
        guard let mentions = try? store.mentions(eventID: id, tiers: tiers), !mentions.isEmpty else { return nil }
        let h = Hotness.score(mentions, now: now)
        let earlier = (try? store.hotness(id, before: now.addingTimeInterval(-6 * 3600))) ?? 0
        let first = mentions.map(\.at).min() ?? now
        let last = mentions.map(\.at).max() ?? now
        let members = ((try? store.items(since: now.addingTimeInterval(-30 * 86_400), statuses: [.written, .accepted])) ?? []).filter { $0.eventID == id }
        let top = members.max { a, b in
            let sa = (try? store.score(a.id))?.combined ?? 0, sb = (try? store.score(b.id))?.combined ?? 0
            return sa < sb
        } ?? members.first
        let title = top.flatMap { t in (try? store.writing(t.id)).map { $0.titleEN.isEmpty ? $0.titleZH : $0.titleEN } } ?? top?.title ?? id
        let e = SignalEvent(id: id, title: title, firstSeen: first, lastSeen: last, hotness: h, rising: Hotness.isRising(now: h, sixHoursAgo: earlier),
                            isNew: Hotness.isNew(firstSeen: first, now: now), sourceCount: Set(mentions.map(\.sourceID)).count, topItemID: top?.id ?? id)
        try? store.saveEvent(e)
        try? store.recordHotness(id, h, at: now)
        return e
    }

    /// Hourly: every event seen in the last two days gets a fresh hotness point.
    func refreshRecentEvents(now: Date = Date()) {
        let tiers = tiers
        for e in (try? store.events(since: now.addingTimeInterval(-48 * 3600))) ?? [] { refreshEvent(e.id, tiers: tiers, now: now) }
    }

    // MARK: - Reads for the card, the digest and the debug channel

    func status(now: Date = Date()) -> Status {
        var s = Status()
        let startOfDay = Calendar.current.startOfDay(for: now)
        s.itemsToday = (try? store.countItems(since: startOfDay)) ?? 0
        s.acceptedToday = ((try? store.items(since: startOfDay, statuses: [.accepted, .written])) ?? []).count
        s.pending = (try? store.countItems(status: .new)) ?? 0
        s.hot = ((try? store.events(since: now.addingTimeInterval(-48 * 3600))) ?? []).sorted { $0.hotness > $1.hotness }.prefix(6).map { $0 }
        s.latestDigest = try? store.latestDigest()
        s.usage = (try? store.usageToday(day: Self.day(now))) ?? [:]
        for src in sources { s.states[src.id] = sourceState(src.id) }
        return s
    }

    func event(_ id: String) -> SignalEvent? { try? store.event(id) }
    func item(_ id: String) -> SignalItem? { try? store.item(id) }
    func writing(_ id: String) -> SignalWriting? { try? store.writing(id) }

    /// Digest candidates: every written item of the window with its writing, score and event.
    func candidates(window: (Date, Date)) -> [DigestComposer.Candidate] {
        let items = ((try? store.items(since: window.0, statuses: [.written])) ?? []).filter { $0.discoveredAt <= window.1 }
        var events: [String: SignalEvent] = [:]
        return items.compactMap { it in
            guard let w = try? store.writing(it.id), let sc = try? store.score(it.id) else { return nil }
            let eid = it.eventID ?? String(it.id.prefix(16))
            let e = events[eid] ?? (try? store.event(eid)) ?? SignalEvent(id: eid, title: it.title, firstSeen: it.discoveredAt, lastSeen: it.discoveredAt, topItemID: it.id)
            events[eid] = e
            let src = source(it.sourceID)
            return DigestComposer.Candidate(id: it.id, eventID: eid, sourceID: it.sourceID, sourceName: src?.name ?? it.sourceID, tier: src?.tier ?? .t2, url: it.url,
                                            titleZH: w.titleZH, titleEN: w.titleEN, summaryZH: w.summaryZH, summaryEN: w.summaryEN, reason: w.reason,
                                            score: sc.combined, hotness: e.hotness, rising: e.rising, isNew: e.isNew, eventSources: e.sourceCount, publishedAt: it.publishedAt ?? it.discoveredAt)
        }
    }

    func recentlyShown(excludingDay: String? = nil) -> [String: Int] { (try? store.recentlyShown(excludingDay: excludingDay)) ?? [:] }
    func digest(day: String) -> (path: String, items: Int, hot: Int)? { try? store.digest(day: day) }
    func saveDigest(day: String, path: String, items: Int, hot: Int, events: [String], at: Date = Date()) { try? store.saveDigest(day: day, path: path, items: items, hot: hot, events: events, at: at) }
    func countSince(_ d: Date) -> Int { (try? store.countItems(since: d)) ?? 0 }
    func bump(_ task: String, now: Date = Date()) { try? store.bump(day: Self.day(now), task: task) }
    func usedToday(now: Date = Date()) -> Int { ((try? store.usageToday(day: Self.day(now))) ?? [:]).values.reduce(0, +) }
    func prune(now: Date = Date()) { try? store.prune(olderThan: 60, now: now) }
    func meta(_ k: String) -> String? { try? store.meta(k) }
    func setMeta(_ k: String, _ v: String) { try? store.setMeta(k, v) }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
