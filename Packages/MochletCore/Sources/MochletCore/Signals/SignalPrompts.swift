import Foundation

/// What the brain is asked, in batches: two independent scores per item, a write-up per accepted
/// item, the relation between two items that look alike, and an overview for a digest.
public enum SignalPrompts {
    public static let scoreSystem = """
You score AI-industry news items for a personal daily signal feed. For each item give a 0–100 score of how much
a practitioner following AI closely should see it today, a category, up to four short tags, the main entity
(company, lab, model or person) and one line of reasons. Judge from the text alone; do not invent facts.
Score 85–100: a real change (new model/product with numbers, open weights, major funding, regulation).
Score 60–84: worth a line in a daily brief. Score 30–59: minor or derivative. Score 0–29: noise, opinion,
listicle, promotion. Return exactly one JSON object.
"""

    public static func scoreSchema() -> JSONValue {
        Schemas.object([
            "scores": Schemas.array(Schemas.object([
                "id": Schemas.string("the item id as given"),
                "score": Schemas.number("0–100"),
                "category": Schemas.string("one of: release, research, funding, policy, product, opinion, tooling, hardware, other"),
                "tags": Schemas.strings("up to four short tags, lowercase"),
                "main_entity": Schemas.string("company, lab, model or person; empty if none"),
                "reasons": Schemas.string("one line"),
            ], required: ["id", "score", "category", "tags", "main_entity", "reasons"]), "one per item, same order"),
        ], required: ["scores"])
    }

    public struct ScoreBatch: Decodable, Sendable {
        public struct Row: Decodable, Sendable {
            public var id: String
            public var score: Double
            public var category: String
            public var tags: [String]
            public var mainEntity: String?
            public var reasons: String
            enum CodingKeys: String, CodingKey { case id, score, category, tags, mainEntity = "main_entity", reasons }
        }
        public var scores: [Row]
    }

    public static func scoreUser(rubric: Rubric, items: [(id: String, source: String, tier: SourceTier, text: String)], shuffled: Bool) -> String {
        var out = "Rubric:\n\(rubric.promptText)\n\nItems (\(items.count)):\n"
        for it in items {
            out += "\n<item id=\"\(it.id)\" source=\"\(it.source)\" tier=\"\(it.tier.label)\">\n\(it.text)\n</item>\n"
        }
        out += "\nScore every item" + (shuffled ? " independently; the order is arbitrary" : "") + "."
        return out
    }

    public static let writeSystem = """
You write a daily AI brief in English. For each item write a title (under 60 characters), then a summary of
two or three sentences, answer-first: what happened, why it matters, what is uncertain. Keep names, numbers
and model names exactly as in the source. Add one line on why it was selected. Return exactly one JSON object.
"""

    public static func writeSchema() -> JSONValue {
        Schemas.object([
            "items": Schemas.array(Schemas.object([
                "id": Schemas.string("the item id as given"),
                "title": Schemas.string("title, under 60 characters"),
                "summary": Schemas.string("summary, 2–3 sentences"),
                "reason": Schemas.string("why it was selected, one line"),
            ], required: ["id", "title", "summary", "reason"]), "one per item"),
        ], required: ["items"])
    }

    public struct WriteBatch: Decodable, Sendable {
        public struct Row: Decodable, Sendable {
            public var id: String
            public var title: String
            public var summary: String
            public var reason: String
        }
        public var items: [Row]
    }

    public static func writeUser(style: String, items: [(id: String, source: String, text: String)]) -> String {
        var out = style.isEmpty ? "" : "Style:\n\(style)\n\n"
        out += "Items (\(items.count)):\n"
        for it in items { out += "\n<item id=\"\(it.id)\" source=\"\(it.source)\">\n\(it.text)\n</item>\n" }
        return out
    }

    public static let pairSystem = """
You decide whether two AI news items are about the same event. SAME_OCCURRENCE: the same announcement or
happening. SAME_STORY: the same unfolding story (follow-ups, reactions, analysis of one event). ROUNDUP: one is
a roundup that merely includes the other. UNRELATED: different events, even if about the same company.
Return exactly one JSON object.
"""

    public static func pairSchema() -> JSONValue {
        Schemas.object([
            "pairs": Schemas.array(Schemas.object([
                "a": Schemas.string("first id"), "b": Schemas.string("second id"),
                "relation": Schemas.string("SAME_OCCURRENCE | SAME_STORY | ROUNDUP | UNRELATED"),
                "confidence": Schemas.number("0–1"),
            ], required: ["a", "b", "relation", "confidence"]), "one per pair"),
        ], required: ["pairs"])
    }

    public struct PairBatch: Decodable, Sendable {
        public struct Row: Decodable, Sendable { public var a: String; public var b: String; public var relation: String; public var confidence: Double }
        public var pairs: [Row]
    }

    public static func pairUser(_ pairs: [(a: (id: String, text: String), b: (id: String, text: String))]) -> String {
        var out = "Pairs (\(pairs.count)):\n"
        for p in pairs {
            out += "\n<pair>\n<a id=\"\(p.a.id)\">\(p.a.text)</a>\n<b id=\"\(p.b.id)\">\(p.b.text)</b>\n</pair>\n"
        }
        return out
    }

    public static let overviewSystem = """
You open a daily AI brief with a short overview: three or four sentences in English, naming the two or three
things that mattered most today and how they connect, with no hype and no bullet points.
Return exactly one JSON object.
"""

    public static func overviewSchema() -> JSONValue { Schemas.object(["overview": Schemas.string("the overview paragraph")], required: ["overview"]) }
    public struct Overview: Decodable, Sendable { public var overview: String }
}
