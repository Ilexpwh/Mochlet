import CryptoKit
import Foundation

/// A cheap typed decision: pick one option. M8 adds scores and booleans and the Jev / on-device backends.
public struct DecisionOption: Sendable, Equatable, Identifiable {
    public var id: String
    public var description: String
    public init(id: String, description: String) {
        self.id = id
        self.description = description
    }
}

public struct DecisionRequest: Sendable, Equatable {
    public var state: String                 // what is being decided about
    public var instructions: String          // how to choose
    public var options: [DecisionOption]
    public var tag: String                   // for caching / logging
    public init(state: String, instructions: String, options: [DecisionOption], tag: String) {
        self.state = state
        self.instructions = instructions
        self.options = options
        self.tag = tag
    }

    /// Cache key: the same question about the same state gives the same answer for a day.
    public var cacheKey: String { "\(tag)|\(options.map(\.id).joined(separator: ","))|\(state)".sha256Hex }
}

public struct DecisionAnswer: Sendable, Equatable, Codable {
    public var choice: String
    public var confidence: Double
    public var probabilities: [String: Double]
    public var backend: String
    public init(choice: String, confidence: Double, probabilities: [String: Double] = [:], backend: String) {
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
        self.backend = backend
    }

    /// Gap between the best and second-best option (1 when there is no second).
    public var margin: Double {
        let sorted = probabilities.values.sorted(by: >)
        guard sorted.count >= 2 else { return 1 }
        return sorted[0] - sorted[1]
    }
}

public protocol DecisionEngine: Sendable {
    var name: String { get }
    func decide(_ request: DecisionRequest) async throws -> DecisionAnswer
}

/// Tries each backend in order; the first answer wins.
public struct CompositeDecisionEngine: DecisionEngine {
    public let name = "composite"
    public var engines: [any DecisionEngine]
    public init(_ engines: [any DecisionEngine]) { self.engines = engines }

    public func decide(_ request: DecisionRequest) async throws -> DecisionAnswer {
        var lastError: Error = DecisionError.noBackend
        for e in engines {
            do { return try await e.decide(request) } catch { lastError = error }
        }
        throw lastError
    }
}

public enum DecisionError: Error, CustomStringConvertible {
    case noBackend
    case badAnswer(String)
    case unavailable(String)
    public var description: String {
        switch self {
        case .noBackend: return "No decision backend is configured."
        case .badAnswer(let s): return "The model did not pick an option: \(s)"
        case .unavailable(let s): return s
        }
    }
}

/// The prompt an LLM-JSON backend sends; shared so every backend phrases the question the same way.
public enum DecisionPrompt {
    public static func text(_ r: DecisionRequest) -> String {
        var s = r.instructions + "\n\nOptions:\n"
        for o in r.options { s += "- \(o.id): \(o.description)\n" }
        s += "\nSituation:\n\(r.state)\n\nAnswer with JSON: {\"choice\": \"<option id>\", \"confidence\": <0-1>, \"reason\": \"…\"}"
        return s
    }

    public static func parse(_ text: String, options: [DecisionOption], backend: String) throws -> DecisionAnswer {
        let ids = Set(options.map(\.id))
        if let v = JSONRepair.extractObject(text), let c = v["choice"].string {
            let id = ids.contains(c) ? c : options.first(where: { $0.id.lowercased() == c.lowercased() || $0.description.lowercased() == c.lowercased() })?.id
            if let id {
                let conf = min(1, max(0, v["confidence"].double ?? 0.7))
                var probs: [String: Double] = [:]
                for o in options { probs[o.id] = o.id == id ? conf : (1 - conf) / Double(max(1, options.count - 1)) }
                return DecisionAnswer(choice: id, confidence: conf, probabilities: probs, backend: backend)
            }
        }
        // A bare id in the text.
        for o in options.sorted(by: { $0.id.count > $1.id.count }) where text.contains(o.id) {
            return DecisionAnswer(choice: o.id, confidence: 0.6, probabilities: [:], backend: backend)
        }
        throw DecisionError.badAnswer(OneLine.collapse(text, limit: 120))
    }
}

extension String {
    public var sha256Hex: String {
        SHA256.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
