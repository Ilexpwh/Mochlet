import Foundation

/// The daily digest: one item per event, ranked by hotness then score, the top twelve (at most two per
/// source) as the selection and up to ten briefs, skipping what the last seven digests already showed
/// unless there is new movement. Rule-assembled; the brain only writes the overview when asked.
public enum DigestComposer {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var id: String            // item id
        public var eventID: String
        public var sourceID: String
        public var sourceName: String
        public var tier: SourceTier
        public var url: String
        public var titleZH: String
        public var titleEN: String
        public var summaryZH: String
        public var summaryEN: String
        public var reason: String
        public var score: Double
        public var hotness: Double
        public var rising: Bool
        public var isNew: Bool
        public var eventSources: Int
        public var publishedAt: Date?
        public init(id: String, eventID: String, sourceID: String, sourceName: String, tier: SourceTier, url: String, titleZH: String, titleEN: String,
                    summaryZH: String, summaryEN: String, reason: String, score: Double, hotness: Double, rising: Bool = false, isNew: Bool = false,
                    eventSources: Int = 1, publishedAt: Date? = nil) {
            self.id = id
            self.eventID = eventID
            self.sourceID = sourceID
            self.sourceName = sourceName
            self.tier = tier
            self.url = url
            self.titleZH = titleZH
            self.titleEN = titleEN
            self.summaryZH = summaryZH
            self.summaryEN = summaryEN
            self.reason = reason
            self.score = score
            self.hotness = hotness
            self.rising = rising
            self.isNew = isNew
            self.eventSources = eventSources
            self.publishedAt = publishedAt
        }
    }

    public struct Selection: Sendable, Equatable {
        public var hot: [Candidate]
        public var selected: [Candidate]
        public var briefs: [Candidate]
        public var all: [Candidate] { hot + selected + briefs }
    }

    /// `recentlyShown`: event ids from the last seven digests, with the source count they had then.
    public static func select(_ candidates: [Candidate], recentlyShown: [String: Int], maxSelected: Int = 12, maxBriefs: Int = 10, perSource: Int = 2) -> Selection {
        var bestPerEvent: [String: Candidate] = [:]
        for c in candidates {
            if let b = bestPerEvent[c.eventID] {
                if (c.score, c.tier.weight) > (b.score, b.tier.weight) { bestPerEvent[c.eventID] = c }
            } else {
                bestPerEvent[c.eventID] = c
            }
        }
        let fresh = bestPerEvent.values.filter { c in
            guard let shown = recentlyShown[c.eventID] else { return true }
            return c.eventSources >= 4 && c.eventSources > shown   // new movement on a story already told
        }
        let ranked = fresh.sorted { l, r in
            if l.hotness != r.hotness { return l.hotness > r.hotness }
            if l.score != r.score { return l.score > r.score }
            return (l.publishedAt ?? .distantPast) > (r.publishedAt ?? .distantPast)
        }
        var selected: [Candidate] = [], briefs: [Candidate] = []
        var perSourceCount: [String: Int] = [:]
        for c in ranked {
            if selected.count < maxSelected, perSourceCount[c.sourceID, default: 0] < perSource {
                selected.append(c)
                perSourceCount[c.sourceID, default: 0] += 1
            } else if briefs.count < maxBriefs {
                briefs.append(c)
            }
        }
        let hot = selected.filter { $0.hotness >= 2.0 && $0.eventSources >= 2 }
        let rest = selected.filter { s in !hot.contains { $0.id == s.id } }
        return Selection(hot: hot, selected: rest, briefs: briefs)
    }

    /// The page: 热点/Hot · 精选/Selected · 简讯/Briefs with footnote links, bilingual by `languages`.
    public static func markdown(date: Date, selection: Selection, overview: String?, languages: [String], calendar: Calendar = .current) -> String {
        let zh = languages.contains("zh"), en = languages.contains("en") || !zh
        let f = DateFormatter()
        f.locale = Locale(identifier: zh ? "zh_CN" : "en_US")
        f.dateFormat = zh ? "yyyy年M月d日 EEEE" : "EEEE, d MMMM yyyy"
        f.calendar = calendar
        var out = "# " + (zh ? "AI 信号 · " : "AI signals · ") + f.string(from: date) + "\n\n"
        if let overview, !overview.isEmpty { out += overview.trimmed + "\n\n" }
        var notes: [String] = []
        func entry(_ c: Candidate, brief: Bool) -> String {
            notes.append("[^e\(notes.count + 1)]: \(c.sourceName) · <\(c.url)>")
            let n = notes.count
            let flags = (c.rising ? (zh ? " ↑" : " ↑") : "") + (c.eventSources >= 2 ? " ×\(c.eventSources)" : "")
            if brief {
                let t = zh && !c.titleZH.isEmpty ? c.titleZH : c.titleEN
                let t2 = zh && en && !c.titleZH.isEmpty && !c.titleEN.isEmpty ? " — \(c.titleEN)" : ""
                return "- \(t)\(t2)\(flags) [^e\(n)]"
            }
            var s = "### " + (zh && !c.titleZH.isEmpty ? c.titleZH : c.titleEN) + flags + " [^e\(n)]\n\n"
            if zh && en && !c.titleEN.isEmpty && !c.titleZH.isEmpty { s += "_\(c.titleEN)_\n\n" }
            if zh && !c.summaryZH.isEmpty { s += c.summaryZH + "\n\n" }
            if en && !c.summaryEN.isEmpty { s += c.summaryEN + "\n\n" }
            if !c.reason.isEmpty { s += "<sub>\(zh ? "入选理由" : "Why") · \(c.reason) · \(c.sourceName) · \(Int(c.score))</sub>\n\n" }
            return s
        }
        if !selection.hot.isEmpty {
            out += "## " + (zh ? "热点" : "Hot") + (zh && en ? " / Hot" : "") + "\n\n"
            for c in selection.hot { out += entry(c, brief: false) }
        }
        if !selection.selected.isEmpty {
            out += "## " + (zh ? "精选" : "Selected") + (zh && en ? " / Selected" : "") + "\n\n"
            for c in selection.selected { out += entry(c, brief: false) }
        }
        if !selection.briefs.isEmpty {
            out += "## " + (zh ? "简讯" : "Briefs") + (zh && en ? " / Briefs" : "") + "\n\n"
            for c in selection.briefs { out += entry(c, brief: true) + "\n" }
            out += "\n"
        }
        if selection.all.isEmpty { out += (zh ? "今天没有值得一提的信号。" : "Nothing worth a line today.") + "\n\n" }
        if !notes.isEmpty { out += notes.joined(separator: "\n") + "\n" }
        return out
    }

    /// The knowledge page for the digest (type digest), sources = the representative URLs.
    public static func page(date: Date, selection: Selection, overview: String?, languages: [String], rubricHash: String, itemsSeen: Int, window: (Date, Date), by: String, now: Date = Date()) -> OKFDocument {
        let day = DateFormatter()
        day.calendar = .current
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        let title = (languages.contains("zh") ? "AI 信号 " : "AI signals ") + day.string(from: date)
        var fm = OKFFrontmatter(type: "digest", title: title, description: OneLine.collapse(overview ?? selection.all.prefix(3).map { $0.titleEN.isEmpty ? $0.titleZH : $0.titleEN }.joined(separator: " · "), limit: 200))
        fm.tags = ["signals", "digest"]
        fm.status = "stable"
        fm.generated = OKFStamp(by: by, at: now)
        fm.sources = selection.all.prefix(40).enumerated().map { i, c in OKFSource(id: "e\(i + 1)", resource: c.url, title: c.titleEN.isEmpty ? c.titleZH : c.titleEN) }
        fm.mochlet = .mapping([
            YAMLPair("kind", .string("digest")),
            YAMLPair("window", .mapping([YAMLPair("from", .string(OKFDate.format(window.0))), YAMLPair("to", .string(OKFDate.format(window.1)))])),
            YAMLPair("items_seen", .int(itemsSeen)),
            YAMLPair("items", .int(selection.all.count)),
            YAMLPair("hot", .int(selection.hot.count)),
            YAMLPair("rubric_hash", .string(String(rubricHash.prefix(12)))),
        ])
        return OKFDocument(frontmatter: fm, body: markdown(date: date, selection: selection, overview: overview, languages: languages))
    }
}
