import Foundation

/// TypeSafe AI's "System One" typed-decision API (Jev): the request and response shapes, kept pure so
/// the app's engine only adds the key and the network call.
public enum JevAPI {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let questionID = "q"

    public static func body(_ r: DecisionRequest, model: String = "jev-latest") -> Data {
        var criteria: [String: JSONValue] = [:]
        for o in r.options { criteria[o.id] = .string(String(o.description.prefix(255))) }
        let question: JSONValue = .object(["type": .string("choice"), "instructions": .string(r.instructions), "criteria": .object(criteria)])
        let root: JSONValue = .object(["state": .string(r.state), "model": .string(model), "questions": .object([questionID: question])])
        return root.data()
    }

    public static func parse(_ data: Data, options: [DecisionOption]) throws -> DecisionAnswer {
        guard let v = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { throw DecisionError.badAnswer("Jev returned no JSON") }
        if let err = v["error"].string ?? v["error"]["message"].string { throw DecisionError.unavailable("Jev: \(err)") }
        let a = v["answers"][questionID]
        guard let choice = a["choice"].string else { throw DecisionError.badAnswer("Jev answer without a choice") }
        let ids = Set(options.map(\.id))
        guard ids.contains(choice) else { throw DecisionError.badAnswer("Jev chose \(choice)") }
        var probs: [String: Double] = [:]
        if case .object(let o) = a["probabilities"] { for (k, p) in o { if let d = p.double, ids.contains(k) { probs[k] = d } } }
        let confidence = a["confidence"].double ?? probs[choice] ?? 0.7
        return DecisionAnswer(choice: choice, confidence: min(1, max(0, confidence)), probabilities: probs, backend: "jev")
    }
}

/// Answers from a table, for tests and replays: by request tag, else by a substring of the state.
public struct FixtureDecisionEngine: DecisionEngine {
    public let name = "fixture"
    public var byTag: [String: String]
    public var byState: [(contains: String, choice: String)]
    public init(byTag: [String: String] = [:], byState: [(contains: String, choice: String)] = []) {
        self.byTag = byTag
        self.byState = byState
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionAnswer {
        let choice = byState.first { request.state.contains($0.contains) }?.choice ?? byTag[request.tag]
        guard let choice, request.options.contains(where: { $0.id == choice }) else { throw DecisionError.unavailable("no fixture for \(request.tag)") }
        return DecisionAnswer(choice: choice, confidence: 0.9, probabilities: [choice: 0.9], backend: name)
    }
}
