import Foundation

/// Retries only idempotent Google GETs. Delivery and the shared transport stay single-attempt.
struct GoogleReadRetry: Sendable {
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var jitter: @Sendable () -> Double = { Double.random(in: 0...1) }
    var now: @Sendable () -> Date = { Date() }

    func send(_ request: URLRequest, http: ConnectorHTTP) async throws -> Data {
        guard (request.httpMethod ?? "GET") == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              request.url?.scheme == "https",
              ["gmail.googleapis.com", "www.googleapis.com", "openidconnect.googleapis.com"].contains(request.url?.host ?? "") else {
            throw MochletError.message("Google read retries require a body-free GET to a supported Google endpoint.")
        }
        var waitBudget: TimeInterval = 15
        for attempt in 0...3 {
            try Task.checkCancellation()
            let failure: any Error
            var response: ConnectorResponse?
            do {
                let result = try await http.response(request)
                try Task.checkCancellation()
                if (200..<300).contains(result.status) { return result.data }
                guard Self.isTransient(result) else { throw ConnectorError.http(result.status) }
                response = result
                failure = ConnectorError.http(result.status)
            } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
                failure = error
            }
            try Task.checkCancellation()
            guard attempt < 3 else { throw failure }
            let random = jitter()
            let exponential = pow(2, Double(attempt)) + (random.isFinite ? min(1, max(0, random)) : 0)
            let serverDelay = response?.retryAfter.flatMap { Self.retryAfter($0, now: now()) } ?? 0
            let delay = max(exponential, serverDelay)
            // Never shorten a server-requested delay to fit the local budget.
            guard delay.isFinite, delay <= waitBudget else { throw failure }
            waitBudget -= delay
            try await sleep(delay)
        }
        preconditionFailure("The final attempt always returns or throws")
    }

    private static func isTransient(_ response: ConnectorResponse) -> Bool {
        if [429, 500, 502, 503, 504].contains(response.status) { return true }
        guard response.status == 403,
              let value = try? JSONDecoder().decode(JSONValue.self, from: response.data) else { return false }
        let errors = value["error"]["errors"].array
        // Mixed authorization/rate errors must not be mistaken for a temporary quota failure.
        return !errors.isEmpty && errors.allSatisfy {
            ["rateLimitExceeded", "userRateLimitExceeded"].contains($0["reason"].string ?? "")
        }
    }

    static func retryAfter(_ raw: String, now: Date) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            // Overflow is still a request to wait longer than our bounded operation allows.
            return Double(value) ?? .infinity
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
