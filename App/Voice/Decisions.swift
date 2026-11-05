import Foundation
import MochletCore
import MochletServices

/// The cheap typed-decision stack shared by routing and voice: Jev (when a TypeSafe key is saved),
/// Apple's on-device model, then the brain as LLM-JSON; answers are cached for a day in the index.
enum Decisions {
    static let jevKeychainAccount = "typesafe"

    @MainActor
    static func engines(app: AppCoordinator, brain: LLMClient?) -> [any DecisionEngine] {
        var engines: [any DecisionEngine] = []
        if let key = KeychainStore.get(jevKeychainAccount), !key.isEmpty { engines.append(JevDecisionEngine(key: key)) }
        if FoundationModelsDecisionEngine.isAvailable { engines.append(FoundationModelsDecisionEngine()) }
        if let brain { engines.append(LLMJSONDecisionEngine(client: brain)) }
        return engines
    }

    @MainActor
    static func describe(app: AppCoordinator) -> String {
        var parts: [String] = []
        if KeychainStore.has(jevKeychainAccount) { parts.append("Jev") }
        if FoundationModelsDecisionEngine.isAvailable { parts.append("on-device") }
        if let b = LLMClient.brain(app) { parts.append(b.label) }
        return parts.isEmpty ? "none" : parts.joined(separator: " → ")
    }

    /// First backend that answers; the answer is cached by request hash.
    @MainActor
    static func decide(_ r: DecisionRequest, app: AppCoordinator, brain: LLMClient? = nil) async -> DecisionAnswer? {
        let engine = app.knowledge.engine
        if let json = await engine.cachedDecision(hash: r.cacheKey), let a = JSONRepair.decode(DecisionAnswer.self, from: json) { return a }
        let engines = engines(app: app, brain: brain ?? LLMClient.brain(app))
        guard !engines.isEmpty, let a = try? await CompositeDecisionEngine(engines).decide(r) else { return nil }
        if let data = try? JSONEncoder().encode(a) { await engine.cacheDecision(hash: r.cacheKey, backend: a.backend, answerJSON: String(decoding: data, as: UTF8.self)) }
        return a
    }
}
