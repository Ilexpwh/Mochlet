import Foundation
import FoundationModels
import MochletCore

/// Apple's on-device model as a typed-decision backend: free, private, well under a second.
public struct FoundationModelsDecisionEngine: DecisionEngine {
    public let name = "foundation-models"
    public init() {}

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func decide(_ r: DecisionRequest) async throws -> DecisionAnswer {
        guard Self.isAvailable else { throw DecisionError.unavailable("Apple Intelligence is not available on this Mac.") }
        let ids = r.options.map(\.id)
        let choice = DynamicGenerationSchema(name: "choice", description: "The id of the chosen option", anyOf: ids)
        let confidence = DynamicGenerationSchema(type: Double.self)
        let root = DynamicGenerationSchema(name: "Decision", properties: [
            DynamicGenerationSchema.Property(name: "choice", description: "The chosen option id", schema: choice),
            DynamicGenerationSchema.Property(name: "confidence", description: "How sure, from 0 to 1", schema: confidence),
        ])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(instructions: r.instructions + " Pick exactly one option id.")
        var prompt = "Options:\n"
        for o in r.options { prompt += "- \(o.id): \(o.description)\n" }
        prompt += "\nSituation:\n\(r.state)"
        let response = try await session.respond(to: prompt, schema: schema, options: GenerationOptions(temperature: 0))
        let id = try response.content.value(String.self, forProperty: "choice")
        let conf = (try? response.content.value(Double.self, forProperty: "confidence")) ?? 0.7
        guard ids.contains(id) else { throw DecisionError.badAnswer(id) }
        var probs: [String: Double] = [:]
        for o in r.options { probs[o.id] = o.id == id ? conf : (1 - conf) / Double(max(1, ids.count - 1)) }
        return DecisionAnswer(choice: id, confidence: min(1, max(0, conf)), probabilities: probs, backend: name)
    }
}
