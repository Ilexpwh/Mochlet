import Foundation

/// AIHOT compatibility: its `industry/sources.json` imports as it is (same field names), WeChat
/// accounts arrive disabled, and an AIHOT instance itself can be a source of kind `aihot` whose feeds
/// are read like RSS.
public enum AIHOTImport {
    public struct Report: Sendable, Equatable {
        public var added: [String]
        public var updated: [String]
        public var skipped: [String]
        public var disabled: [String]
    }

    public static func parse(_ data: Data) throws -> [SignalSource] {
        let decoder = JSONDecoder()
        // `{"version":1,"sources":[…]}` (AIHOT's file) or a bare array of sources.
        let first = data.first { !" \t\r\n".utf8.contains($0) }
        if first == UInt8(ascii: "[") { return try decoder.decode([SignalSource].self, from: data) }
        return try decoder.decode(SourcesFile.self, from: data).sources
    }

    /// Merges into the user's list: same id → updated config/tier/tags, user's `enabled` kept.
    public static func merge(_ incoming: [SignalSource], into existing: [SignalSource]) -> (sources: [SignalSource], report: Report) {
        var out = existing
        var report = Report(added: [], updated: [], skipped: [], disabled: [])
        for var s in incoming {
            if s.kind == .mpAccount { s.enabled = false }
            if let i = out.firstIndex(where: { $0.id == s.id }) {
                var cur = out[i]
                cur.name = s.name
                cur.kind = s.kind
                cur.tier = s.tier
                cur.participationMode = s.participationMode
                cur.intervalMinutes = s.intervalMinutes
                cur.tags = s.tags
                cur.config = s.config
                cur.ownerEntityID = s.ownerEntityID
                if cur == out[i] { report.skipped.append(s.id) } else { out[i] = cur; report.updated.append(s.id) }
            } else {
                out.append(s)
                report.added.append(s.id)
                if !s.enabled { report.disabled.append(s.id) }
            }
        }
        return (out, report)
    }

    /// Feed URLs of an AIHOT instance: `feeds` from its config, else the default feed paths.
    public static func feedURLs(_ source: SignalSource) -> [URL] {
        guard let base = source.config["baseUrl"]?.string, let baseURL = URL(string: base) else { return [] }
        let feeds = source.config["feeds"]?.array?.compactMap(\.string) ?? ["/feed.xml", "/feed/daily.xml"]
        return feeds.compactMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
    }

    public static func trustsRemoteScores(_ source: SignalSource) -> Bool { source.config["trustRemoteScores"]?.bool ?? false }
}

/// The starter list: AIHOT's eighteen demo feeds plus a few more, all checked to answer with RSS or Atom.
public enum DefaultSources {
    public static func make() -> [SignalSource] {
        func rss(_ id: String, _ name: String, _ url: String, _ tier: SourceTier, _ minutes: Int, _ tags: [String], owner: String? = nil) -> SignalSource {
            SignalSource(id: id, name: name, kind: .rss, tier: tier, participationMode: .editorial, intervalMinutes: minutes, tags: tags, enabled: true,
                         config: ["feedUrl": .string(url)], ownerEntityID: owner)
        }
        return [
            rss("rss-openai-news", "OpenAI News", "https://openai.com/news/rss.xml", .t1, 120, ["官方"], owner: "openai"),
            rss("rss-google-deepmind", "Google DeepMind", "https://deepmind.google/blog/rss.xml", .t1, 120, ["官方"], owner: "google"),
            rss("rss-google-research", "Google Research", "https://research.google/blog/rss/", .t1, 120, ["官方", "研究"], owner: "google"),
            rss("rss-hugging-face", "Hugging Face Blog", "https://huggingface.co/blog/feed.xml", .t1, 120, ["官方", "开源"], owner: "hugging-face"),
            rss("rss-microsoft-research", "Microsoft Research", "https://www.microsoft.com/en-us/research/feed/", .t1, 120, ["官方", "研究"], owner: "microsoft"),
            rss("rss-nvidia-blog", "NVIDIA Blog", "https://blogs.nvidia.com/feed/", .t1, 120, ["官方"], owner: "nvidia"),
            rss("rss-aws-ml", "AWS Machine Learning Blog", "https://aws.amazon.com/blogs/machine-learning/feed/", .t1, 120, ["官方", "教程"], owner: "amazon"),
            rss("rss-github-ai", "GitHub Blog · AI & ML", "https://github.blog/ai-and-ml/feed/", .t1, 120, ["官方"], owner: "github"),
            rss("rss-mistral", "Mistral AI", "https://mistral.ai/news/rss", .t1, 120, ["官方"], owner: "mistral"),
            rss("rss-bair", "Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml", .t1, 180, ["研究"]),
            rss("rss-the-verge-ai", "The Verge · AI", "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml", .t2, 60, ["媒体"]),
            rss("rss-techcrunch-ai", "TechCrunch · AI", "https://techcrunch.com/category/artificial-intelligence/feed/", .t2, 60, ["媒体"]),
            rss("rss-ars-technica-ai", "Ars Technica · AI", "https://arstechnica.com/ai/feed/", .t2, 60, ["媒体"]),
            rss("rss-mit-tech-review-ai", "MIT Technology Review · AI", "https://www.technologyreview.com/topic/artificial-intelligence/feed", .t2, 120, ["媒体"]),
            rss("rss-the-decoder", "The Decoder", "https://the-decoder.com/feed/", .t2, 60, ["媒体"]),
            rss("rss-simon-willison", "Simon Willison", "https://simonwillison.net/atom/everything/", .t2, 120, ["个人"]),
            rss("rss-import-ai", "Import AI", "https://importai.substack.com/feed", .t2, 180, ["个人", "周刊"]),
            rss("rss-latent-space", "Latent Space", "https://www.latent.space/feed", .t2, 180, ["个人"]),
            rss("rss-qbitai", "量子位", "https://www.qbitai.com/feed", .t1_5, 60, ["媒体", "中文"]),
            rss("rss-hn-ai", "Hacker News · AI (50+ points)", "https://hnrss.org/newest?q=AI&points=50", .t2, 60, ["社区"]),
            rss("rss-arxiv-cs-ai", "arXiv cs.AI", "https://export.arxiv.org/rss/cs.AI", .t2, 240, ["研究", "论文"]),
        ]
    }
}
