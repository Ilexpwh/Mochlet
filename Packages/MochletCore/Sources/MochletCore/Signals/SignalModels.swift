import Foundation

/// AI signals: sources the user follows, the items they yield, what the brain made of them, and the
/// events they cluster into. The source file keeps AIHOT's field names so an AIHOT `sources.json`
/// imports unchanged.
public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case rss, webList = "web_list", jsonList = "json_list", xSearch = "x_search", aihot, external, mpAccount = "mp_account"
    public var label: String {
        switch self {
        case .rss: return "RSS"
        case .webList: return "Web list"
        case .jsonList: return "JSON list"
        case .xSearch: return "X search"
        case .aihot: return "AIHOT"
        case .external: return "External"
        case .mpAccount: return "WeChat"
        }
    }
}

public enum SourceTier: String, Codable, Sendable, CaseIterable {
    case t1 = "T1", t1_5 = "T1_5", t2 = "T2"
    /// Hotness weight: how much one more source of this tier adds.
    public var weight: Double {
        switch self { case .t1: return 1.0; case .t1_5: return 0.8; case .t2: return 0.6 }
    }
    /// Default acceptance threshold on one 0–100 score (two independent scores must sum to twice it).
    public var defaultThreshold: Double {
        switch self { case .t1: return 60; case .t1_5: return 65; case .t2: return 76 }
    }
    public var label: String { rawValue.replacingOccurrences(of: "_", with: ".") }
}

public enum ParticipationMode: String, Codable, Sendable, CaseIterable {
    case editorial, hotSignal = "hot_signal", isolated
}

public struct SignalSource: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public var tier: SourceTier
    public var participationMode: ParticipationMode
    public var intervalMinutes: Int
    public var tags: [String]
    public var enabled: Bool
    public var config: [String: JSONValue]
    public var ownerEntityID: String?

    public init(id: String, name: String, kind: SourceKind, tier: SourceTier = .t2, participationMode: ParticipationMode = .editorial,
                intervalMinutes: Int = 60, tags: [String] = [], enabled: Bool = true, config: [String: JSONValue] = [:], ownerEntityID: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.tier = tier
        self.participationMode = participationMode
        self.intervalMinutes = intervalMinutes
        self.tags = tags
        self.enabled = enabled
        self.config = config
        self.ownerEntityID = ownerEntityID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, tier, tags, enabled, config
        case participationMode = "participation_mode", intervalMinutes = "interval_minutes", ownerEntityID = "owner_entity_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        let kindRaw = try c.decodeIfPresent(String.self, forKey: .kind) ?? "rss"
        kind = SourceKind(rawValue: kindRaw) ?? .external
        tier = SourceTier(rawValue: try c.decodeIfPresent(String.self, forKey: .tier) ?? "T2") ?? .t2
        participationMode = ParticipationMode(rawValue: try c.decodeIfPresent(String.self, forKey: .participationMode) ?? "editorial") ?? .editorial
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        config = try c.decodeIfPresent([String: JSONValue].self, forKey: .config) ?? [:]
        ownerEntityID = try c.decodeIfPresent(String.self, forKey: .ownerEntityID)
        // WeChat accounts need a paid relay AIHOT talks to; here they import disabled, as AIHOT's EXCLUDE_MP does.
        enabled = (try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true) && kind != .mpAccount && SourceKind(rawValue: kindRaw) != nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(tier, forKey: .tier)
        try c.encode(participationMode, forKey: .participationMode)
        try c.encode(intervalMinutes, forKey: .intervalMinutes)
        try c.encode(tags, forKey: .tags)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(config, forKey: .config)
        try c.encodeIfPresent(ownerEntityID, forKey: .ownerEntityID)
    }

    public var url: String? {
        switch kind {
        case .rss: return config["feedUrl"]?.string ?? config["url"]?.string
        case .aihot: return config["baseUrl"]?.string
        case .xSearch: return config["query"]?.string
        default: return config["url"]?.string
        }
    }
}

public struct SourcesFile: Codable, Sendable, Equatable {
    public var version: Int
    public var sources: [SignalSource]
    public init(version: Int = 1, sources: [SignalSource]) {
        self.version = version
        self.sources = sources
    }
    enum CodingKeys: String, CodingKey { case version, sources }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sources = try c.decode([SignalSource].self, forKey: .sources)
    }
}

public enum ItemStatus: String, Sendable, Codable {
    case new, prefiltered, scored, accepted, rejected, written
}

/// One thing a source yielded.
public struct SignalItem: Sendable, Equatable, Identifiable {
    public var id: String                 // sha256 of the canonical URL (or of source+external id when there is no URL)
    public var sourceID: String
    public var externalID: String
    public var url: String
    public var canonicalURL: String
    public var title: String
    public var titleNorm: String
    public var summary: String
    public var body: String
    public var author: String?
    public var publishedAt: Date?
    public var discoveredAt: Date
    public var status: ItemStatus
    public var eventID: String?
    public var backfill: Bool
    public var simhash: UInt64
    public var language: String?

    public init(sourceID: String, externalID: String, url: String, title: String, summary: String = "", body: String = "", author: String? = nil,
                publishedAt: Date? = nil, discoveredAt: Date = Date(), backfill: Bool = false, language: String? = nil) {
        self.sourceID = sourceID
        self.externalID = externalID
        self.url = url
        let canonical = url.isEmpty ? "" : URLCanonicalizer.canonical(url)
        self.canonicalURL = canonical
        self.id = (canonical.isEmpty ? "\(sourceID):\(externalID)" : canonical).sha256Hex
        self.title = title
        self.titleNorm = SignalText.normalizedTitle(title)
        self.summary = summary
        self.body = body
        self.author = author
        self.publishedAt = publishedAt
        self.discoveredAt = discoveredAt
        self.status = .new
        self.eventID = nil
        self.backfill = backfill
        self.simhash = SimHash.hash(title + " " + summary.prefix(400))
        self.language = language
    }

    /// The text the scorer and writer see: title, then summary or body, capped.
    public func text(limit: Int = 2400) -> String {
        let bodyText = body.isEmpty ? summary : body
        return String((title + "\n\n" + bodyText).prefix(limit))
    }
}

public struct SignalScore: Sendable, Equatable, Codable {
    public var score1: Double
    public var score2: Double
    public var category: String
    public var tags: [String]
    public var mainEntity: String?
    public var reasons: String
    public var rubricHash: String
    public init(score1: Double, score2: Double, category: String, tags: [String], mainEntity: String? = nil, reasons: String, rubricHash: String) {
        self.score1 = score1
        self.score2 = score2
        self.category = category
        self.tags = tags
        self.mainEntity = mainEntity
        self.reasons = reasons
        self.rubricHash = rubricHash
    }
    public var combined: Double { (score1 + score2) / 2 }
}

public struct SignalWriting: Sendable, Equatable, Codable {
    public var title: String
    public var summary: String
    public var reason: String
    public init(title: String, summary: String, reason: String) {
        self.title = title
        self.summary = summary
        self.reason = reason
    }
    // The keys stay `title_en` / `summary_en` so files written by earlier versions still decode.
    enum CodingKeys: String, CodingKey { case title = "title_en", summary = "summary_en", reason }
}

public enum EventRelation: String, Sendable, Codable {
    case sameOccurrence = "SAME_OCCURRENCE", sameStory = "SAME_STORY", unrelated = "UNRELATED", roundup = "ROUNDUP"
    /// Same event when either side says the same thing happened, or the same story unfolds.
    public var joins: Bool { self == .sameOccurrence || self == .sameStory }
}

public struct SignalEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var hotness: Double
    public var rising: Bool
    public var isNew: Bool
    public var sourceCount: Int
    public var topItemID: String
    public init(id: String, title: String, firstSeen: Date, lastSeen: Date, hotness: Double = 0, rising: Bool = false, isNew: Bool = true, sourceCount: Int = 1, topItemID: String) {
        self.id = id
        self.title = title
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.hotness = hotness
        self.rising = rising
        self.isNew = isNew
        self.sourceCount = sourceCount
        self.topItemID = topItemID
    }
}

/// An item as the push endpoint and the watch folder take it (AIHOT's external shape).
public struct ExternalItem: Codable, Sendable, Equatable {
    public var title: String
    public var url: String
    public var summary: String?
    public var publishedAt: String?
    public var source: String?
    public var externalID: String?
    public init(title: String, url: String, summary: String? = nil, publishedAt: String? = nil, source: String? = nil, externalID: String? = nil) {
        self.title = title
        self.url = url
        self.summary = summary
        self.publishedAt = publishedAt
        self.source = source
        self.externalID = externalID
    }
    enum CodingKeys: String, CodingKey { case title, url, summary, publishedAt = "published_at", source, externalID = "external_id" }

    public static func parse(_ json: JSONValue) -> [ExternalItem] {
        let list = json["items"].array ?? json.array ?? []
        return list.compactMap { v in
            guard let title = v["title"].string, !title.isEmpty, let url = v["url"].string, SignalText.isWebURL(url) else { return nil }
            return ExternalItem(title: title, url: url, summary: v["summary"].string, publishedAt: v["published_at"].string ?? v["publishedAt"].string,
                                source: v["source"].string, externalID: v["external_id"].string ?? v["id"].string)
        }
    }
}

/// Text helpers shared by dedupe, prefilter and clustering.
public enum SignalText {
    /// Only http(s) links with a host are signals; feeds and pushed items may carry anything else
    /// (`file:`, `javascript:`, custom schemes) and nothing downstream should open or fetch those.
    public static func isWebURL(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// `link` is on `site`'s own site: the same host, or a true subdomain of the site's host (with a
    /// leading `www.` dropped from the site, so `openai.com/news/rss.xml` covers `www.openai.com`).
    /// Hosts that are addresses must be identical; no suffix heuristics (`foo.github.io` is not `github.io`).
    public static func sameSite(_ link: String?, _ site: String?) -> Bool {
        guard let link, let site, isWebURL(link), isWebURL(site),
              let hl = URL(string: link)?.host?.lowercased(), var hs = URL(string: site)?.host?.lowercased() else { return false }
        if hl == hs { return true }
        let numeric = { (h: String) in h.contains(":") || h.allSatisfy { $0.isNumber || $0 == "." } }
        if numeric(hl) || numeric(hs) { return false }
        if hs.hasPrefix("www.") { hs.removeFirst(4) }
        return hl == hs || hl.hasSuffix("." + hs)
    }

    public static func normalizedTitle(_ t: String) -> String {
        let folded = t.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        var lastSpace = false
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) || isCJK(ch) {
                out.unicodeScalars.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out += " "
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Latin words plus CJK character bigrams, lowercased.
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var word = ""
        var prevCJK: Character?
        func flush() { if word.count >= 2 { out.append(word) }; word = "" }
        for ch in s.lowercased() {
            if let u = ch.unicodeScalars.first, isCJK(u) {
                flush()
                if let p = prevCJK { out.append(String(p) + String(ch)) }
                prevCJK = ch
            } else if ch.isLetter || ch.isNumber {
                word.append(ch)
                prevCJK = nil
            } else {
                flush()
                prevCJK = nil
            }
        }
        flush()
        return out
    }

    public static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a), sb = Set(b)
        guard !sa.isEmpty, !sb.isEmpty else { return 0 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    /// Dominant script: "zh" when a third or more of the letters are CJK, else "en".
    public static func language(_ s: String) -> String {
        var cjk = 0, letters = 0
        for u in s.unicodeScalars {
            if isCJK(u) { cjk += 1; letters += 1 } else if CharacterSet.letters.contains(u) { letters += 1 }
        }
        return letters > 0 && Double(cjk) / Double(letters) >= 0.33 ? "zh" : "en"
    }
}

/// 64-bit simhash over the text's tokens: near-duplicate titles differ in a few bits.
public enum SimHash {
    public static func hash(_ text: String) -> UInt64 {
        let toks = SignalText.tokens(text)
        guard !toks.isEmpty else { return 0 }
        var acc = [Int](repeating: 0, count: 64)
        for t in toks {
            let h = fnv1a(t)
            for bit in 0..<64 { acc[bit] += (h >> UInt64(bit)) & 1 == 1 ? 1 : -1 }
        }
        var out: UInt64 = 0
        for bit in 0..<64 where acc[bit] > 0 { out |= 1 << UInt64(bit) }
        return out
    }

    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }
}
