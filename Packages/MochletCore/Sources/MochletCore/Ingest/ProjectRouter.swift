import Foundation

/// Decides where a report belongs: a registered project or the inbox. Pure: the decision engine
/// and the priors are passed in; the result says whether to ask.
public enum ProjectRouter {
    public struct Candidate: Sendable, Equatable {
        public var slug: String
        public var name: String
        public var description: String
        public var tags: [String]
        public var recentTitles: [String]
        public init(slug: String, name: String, description: String, tags: [String] = [], recentTitles: [String] = []) {
            self.slug = slug
            self.name = name
            self.description = description
            self.tags = tags
            self.recentTitles = recentTitles
        }
    }

    public struct Verdict: Sendable, Equatable {
        public var slug: String?           // nil = inbox
        public var confidence: Double
        public var ask: Bool
        public var question: ProjectQuestion?
        public var backend: String
    }

    public static let inboxID = "inbox"

    public static func request(draft: ReportDraft, host: String?, sourceDirectory: String?, candidates: [Candidate]) -> DecisionRequest {
        var state = "Title: \(draft.title)\nOne-liner: \(draft.oneLiner)\nKind: \(draft.contentKind)\nTags: \(draft.tags.joined(separator: ", "))"
        if !draft.entities.isEmpty { state += "\nEntities: " + draft.entities.prefix(8).map(\.name).joined(separator: ", ") }
        if let host { state += "\nFrom: \(host)" }
        if let sourceDirectory { state += "\nFolder: \(sourceDirectory)" }
        if let s = draft.suggestedProject, !s.isEmpty { state += "\nThe analyst suggested: \(s)" }
        var options = candidates.map { c -> DecisionOption in
            var d = c.name
            if !c.description.isEmpty { d += " — " + c.description }
            if !c.tags.isEmpty { d += " [" + c.tags.joined(separator: ", ") + "]" }
            if !c.recentTitles.isEmpty { d += " (recent: " + c.recentTitles.prefix(3).joined(separator: "; ") + ")" }
            return DecisionOption(id: c.slug, description: String(d.prefix(255)))
        }
        options.append(DecisionOption(id: inboxID, description: "None of the projects: general reading, keep in the inbox"))
        return DecisionRequest(state: state, instructions: "Which project does this source belong to? Pick the project whose work it directly serves; pick inbox when it is general interest or fits no project.",
                               options: options, tag: "project-route")
    }

    /// Applies priors (host/tag/dir → project weights) and the ask thresholds.
    public static func verdict(answer: DecisionAnswer, candidates: [Candidate], priors: [(key: String, project: String, weight: Double)], priorKeys: [String],
                               askBelow: Double = 0.7, askGapBelow: Double = 0.2) -> Verdict {
        var probs = answer.probabilities
        if probs.isEmpty { probs = [answer.choice: answer.confidence] }
        for p in priors where priorKeys.contains(p.key) {
            probs[p.project, default: 0.05] *= p.weight
        }
        let total = probs.values.reduce(0, +)
        if total > 0 { for k in probs.keys { probs[k]! /= total } }
        let ranked = probs.sorted { $0.value > $1.value }
        guard let best = ranked.first else {
            return Verdict(slug: nil, confidence: 0, ask: true, question: question(from: ranked, candidates: candidates, suggested: nil), backend: answer.backend)
        }
        let gap = ranked.count > 1 ? best.value - ranked[1].value : 1
        let slug: String? = best.key == inboxID ? nil : best.key
        let ask = candidates.count > 0 && (best.value < askBelow || gap < askGapBelow)
        return Verdict(slug: slug, confidence: best.value, ask: ask, question: ask ? question(from: ranked, candidates: candidates, suggested: best.key) : nil, backend: answer.backend)
    }

    public static func question(from ranked: [(key: String, value: Double)], candidates: [Candidate], suggested: String?) -> ProjectQuestion {
        var options: [ProjectQuestion.Option] = []
        if ranked.isEmpty { return ProjectQuestion(options: candidates.map { ProjectQuestion.Option(slug: $0.slug, name: $0.name, confidence: $0.slug == suggested ? 1 : 0) } + [ProjectQuestion.Option(slug: nil, name: "Inbox", confidence: suggested == nil ? 1 : 0)], suggested: suggested) }
        for (k, v) in ranked.prefix(4) {
            if k == inboxID { options.append(ProjectQuestion.Option(slug: nil, name: "Inbox", confidence: v)) }
            else if let c = candidates.first(where: { $0.slug == k }) { options.append(ProjectQuestion.Option(slug: k, name: c.name, confidence: v)) }
        }
        if !options.contains(where: { $0.slug == nil }) { options.append(ProjectQuestion.Option(slug: nil, name: "Inbox", confidence: 0)) }
        return ProjectQuestion(options: options, suggested: suggested == inboxID ? nil : suggested)
    }

    /// No projects: nothing to decide.
    public static func trivial() -> Verdict { Verdict(slug: nil, confidence: 1, ask: false, question: nil, backend: "none") }

    /// Prior updates after a correction: +0.5 for the chosen project on every key, −0.25 for the rejected one.
    public static func priorDeltas(keys: [String], chosen: String?, rejected: String?) -> [(key: String, project: String, delta: Double)] {
        var out: [(String, String, Double)] = []
        for k in keys {
            if let c = chosen { out.append((k, c, 0.5)) }
            if let r = rejected, r != chosen { out.append((k, r, -0.25)) }
        }
        return out
    }
}
