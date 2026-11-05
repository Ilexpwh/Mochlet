import Foundation

/// `~/Mochlet/signals/rubric.md`: what counts as a signal. Frontmatter carries thresholds, weights,
/// languages and category floors; the sections carry the industry terms, importance criteria, what to
/// downrank, what never gets through and the writing style. The hash of the whole file is stored on
/// every score so a changed rubric does not silently mix with old scores.
public struct Rubric: Sendable, Equatable {
    public var thresholds: [SourceTier: Double]
    public var weights: [SourceTier: Double]
    public var languages: [String]
    public var categoryFloors: [String: Double]
    public var industryTerms: [String]
    public var importance: String
    public var downrank: String
    public var deny: [String]
    public var style: String
    public var hash: String
    public var text: String

    public static let fileName = "rubric.md"

    public static let defaultText = """
---
thresholds: {T1: 60, T1_5: 65, T2: 76}
weights: {T1: 1.0, T1_5: 0.8, T2: 0.6}
languages: [zh, en]
category_floors: {release: 55, research: 60, funding: 65, policy: 65, opinion: 80}
---

# Signals rubric

## Industry terms

AI, LLM, GPT, Claude, Gemini, Llama, Mistral, DeepSeek, Qwen, Kimi, agent, agentic, MCP, RAG, fine-tuning,
inference, GPU, TPU, NPU, CUDA, transformer, diffusion, multimodal, embedding, vector database, open weights,
benchmark, alignment, safety, RLHF, speech, vision, robotics, foundation model, copilot, coding agent,
大模型, 智能体, 推理, 开源, 算力, 多模态, 自动驾驶, 具身智能

## Importance criteria

- A new model, product or capability from a lab or a company people use, with numbers or a release date.
- A change in how AI is built or sold: pricing, open weights, hardware, regulation, a large funding round.
- A result that changes what practitioners should do next week.
- First-hand sources (the lab's own post, the paper, the filing) over commentary.

## Must downrank

- Opinion without new facts, listicles, "X ways to", sponsored content, recycled press releases.
- Incremental version bumps, minor integrations, hiring news.
- Anything whose only novelty is being about a famous company.

## Prefilter deny

- giveaway
- webinar
- sponsored
- coupon
- hiring
- job opening

## Writing style

Answer-first. One sentence of what happened, one of why it matters, one of what is uncertain. Numbers and
names as written in the source. Chinese and English each natural, not a translation of the other.
"""

    public static func parse(_ text: String) -> Rubric {
        var r = Rubric(thresholds: [:], weights: [:], languages: ["zh", "en"], categoryFloors: [:], industryTerms: [], importance: "", downrank: "", deny: [], style: "", hash: text.sha256Hex, text: text)
        var body = text
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let fm = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            body = String(text[end.upperBound...])
            if let node = try? YAMLLite.parse(fm) {
                for t in SourceTier.allCases {
                    if let v = node["thresholds"]?[t.rawValue]?.string.flatMap(Double.init) { r.thresholds[t] = v }
                    if let v = node["weights"]?[t.rawValue]?.string.flatMap(Double.init) { r.weights[t] = v }
                }
                if let l = node["languages"]?.stringArray, !l.isEmpty { r.languages = l }
                if let floors = node["category_floors"]?.pairs {
                    for p in floors { if let v = p.value.string.flatMap(Double.init) { r.categoryFloors[p.key] = v } }
                }
            }
        }
        let sections = Self.sections(body)
        r.industryTerms = Self.terms(sections["industry terms"] ?? "")
        r.importance = sections["importance criteria"] ?? ""
        r.downrank = sections["must downrank"] ?? ""
        r.deny = Self.bullets(sections["prefilter deny"] ?? "").map { $0.lowercased() }
        r.style = sections["writing style"] ?? ""
        return r
    }

    public func threshold(_ tier: SourceTier) -> Double { thresholds[tier] ?? tier.defaultThreshold }
    public func weight(_ tier: SourceTier) -> Double { weights[tier] ?? tier.weight }

    /// The prompt-side rubric: criteria, downrank and terms, without the deny list and the frontmatter.
    public var promptText: String {
        var out = ""
        if !industryTerms.isEmpty { out += "Industry terms: " + industryTerms.joined(separator: ", ") + "\n\n" }
        if !importance.isEmpty { out += "What matters:\n" + importance + "\n\n" }
        if !downrank.isEmpty { out += "Downrank:\n" + downrank + "\n\n" }
        if !categoryFloors.isEmpty { out += "Categories: " + categoryFloors.keys.sorted().joined(separator: ", ") + "\n" }
        return out.trimmed
    }

    static func sections(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        var current: String?
        var buf: [String] = []
        func flush() { if let c = current { out[c] = buf.joined(separator: "\n").trimmed }; buf = [] }
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                current = String(line.dropFirst(3)).trimmed.lowercased()
            } else if current != nil {
                buf.append(line)
            }
        }
        flush()
        return out
    }

    static func terms(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\n", with: ",").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func bullets(_ s: String) -> [String] {
        s.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmed
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
            return String(t.dropFirst(2)).trimmed
        }
    }
}

/// The free gate before any model sees an item.
public enum Prefilter {
    public enum Verdict: Sendable, Equatable { case pass, denied(String), offTopic }

    public static func check(title: String, summary: String, tier: SourceTier, rubric: Rubric) -> Verdict {
        let hay = (title + " " + summary).lowercased()
        for d in rubric.deny where !d.isEmpty && hay.contains(d) { return .denied(d) }
        if tier == .t2, !rubric.industryTerms.isEmpty {
            let hit = rubric.industryTerms.contains { term in
                let t = term.lowercased()
                guard !t.isEmpty else { return false }
                if t.count <= 3, t.allSatisfy({ $0.isLetter && $0.isASCII }) {
                    // Short Latin terms (AI, GPU) must stand as words.
                    return hay.range(of: "\\b\(NSRegularExpression.escapedPattern(for: t))\\b", options: .regularExpression) != nil
                }
                return hay.contains(t)
            }
            if !hit { return .offTopic }
        }
        return .pass
    }
}
