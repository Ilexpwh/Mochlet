import Foundation
import MochletCore

/// TypeSafe AI "System One" (Jev): ~200–500 ms typed choices. The key lives in the Keychain.
struct JevDecisionEngine: DecisionEngine {
    let name = "jev"
    let key: String
    var timeout: Double = 3

    func decide(_ request: DecisionRequest) async throws -> DecisionAnswer {
        var req = URLRequest(url: JevAPI.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = JevAPI.body(request)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw DecisionError.unavailable("Jev: \(error.localizedDescription)") }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DecisionError.unavailable("Jev answered \(http.statusCode)" + (http.statusCode == 401 ? " (check the key)" : ""))
        }
        return try JevAPI.parse(data, options: request.options)
    }

    /// Settings → Probe: one trivial choice, timed.
    static func probe(key: String) async -> String {
        let r = DecisionRequest(state: "The user said: what time is it?", instructions: "Is this a question or a command?",
                                options: [DecisionOption(id: "question", description: "asks for information"), DecisionOption(id: "command", description: "asks for an action")], tag: "probe")
        let t0 = Date()
        do {
            let a = try await JevDecisionEngine(key: key).decide(r)
            return "Jev answered \(a.choice) (\(Int((a.confidence * 100).rounded()))%) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms"
        } catch {
            return ErrorText.describe(error)
        }
    }
}
