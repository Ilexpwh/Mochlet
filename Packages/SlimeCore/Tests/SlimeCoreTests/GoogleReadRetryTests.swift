import Foundation
import Testing
@testable import SlimeCore

private actor ReadRetryFixture {
    enum Step: Sendable { case response(ConnectorResponse), network(URLError.Code) }
    var steps: [Step]
    var requests: [URLRequest] = []
    var delays: [Double] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) throws -> ConnectorResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw MochletError.message("Unexpected extra attempt") }
        switch steps.removeFirst() {
        case .response(let response): return response
        case .network(let code): throw URLError(code)
        }
    }
    func wait(_ delay: Double) { delays.append(delay) }
}

private func retryResponse(_ status: Int, reasons: [String] = [], after: String? = nil) -> ConnectorResponse {
    let value: JSONValue = .object(["error": .object(["errors": .array(reasons.map { .object(["reason": .string($0)]) })])])
    return .init(data: try! JSONEncoder().encode(value), status: status, retryAfter: after)
}
private func retryReader(_ fixture: ReadRetryFixture) -> GoogleReader {
    let account = ConnectedAccount(provider: "google", remoteID: "fixture", label: "fixture", scopes: [GoogleScope.mail])
    var reader = GoogleReader(account: account, token: "fixture", http: .init { try await fixture.send($0) })
    reader.readRetry = GoogleReadRetry(sleep: { await fixture.wait($0) }, jitter: { 0 }, now: { Date(timeIntervalSince1970: 0) })
    return reader
}

@Test func googleReadRetriesKeepExactRequestAndBoundBackoff() async throws {
    let fixture = ReadRetryFixture([
        .response(retryResponse(429)), .response(retryResponse(403, reasons: ["userRateLimitExceeded"])),
        .response(retryResponse(503)), .response(.init(data: Data("{\"threads\":[]}".utf8), status: 200))])
    let reader = retryReader(fixture)
    let result = try await reader.get("gmail.googleapis.com", ["gmail", "v1", "users", "me", "threads"], ["pageToken": "exact-page"])
    #expect(result["threads"] == .array([]))
    #expect(await fixture.delays == [1, 2, 4])
    let requests = await fixture.requests
    #expect(requests.count == 4)
    #expect(requests.allSatisfy { $0 == requests[0] })

    let exhausted = ReadRetryFixture(Array(repeating: .response(retryResponse(503)), count: 4))
    await #expect(throws: (any Error).self) { try await retryReader(exhausted).get("gmail.googleapis.com", ["fixture"]) }
    #expect(await exhausted.requests.count == 4)
    #expect(await exhausted.delays == [1, 2, 4])

    for code in [URLError.timedOut, .networkConnectionLost] {
        let recovering = ReadRetryFixture([.network(code), .response(.init(data: Data("{}".utf8), status: 200))])
        _ = try await retryReader(recovering).get("gmail.googleapis.com", ["fixture"])
        #expect(await recovering.requests.count == 2)
    }
}

@Test func googleReadRetriesRespectServerWaitAndRejectPermanentFailures() async throws {
    let date = "Thu, 01 Jan 1970 00:00:05 GMT"
    #expect(GoogleReadRetry.retryAfter(date, now: Date(timeIntervalSince1970: 0)) == 5)
    #expect(GoogleReadRetry.retryAfter(date, now: Date(timeIntervalSince1970: 6)) == 0)
    #expect(GoogleReadRetry.retryAfter("-1", now: Date()) == nil)
    #expect(GoogleReadRetry.retryAfter("nonsense", now: Date()) == nil)
    let fixture = ReadRetryFixture([.response(retryResponse(429, after: date)), .response(retryResponse(503, after: "11"))])
    await #expect(throws: (any Error).self) { try await retryReader(fixture).get("gmail.googleapis.com", ["fixture"]) }
    #expect(await fixture.requests.count == 2)
    #expect(await fixture.delays == [5]) // 11 cannot fit the remaining ten-second budget.

    let failures: [ReadRetryFixture.Step] = [
        .response(retryResponse(401)), .response(retryResponse(404)), .response(retryResponse(410)),
        .response(retryResponse(403)), .response(retryResponse(403, reasons: ["dailyLimitExceeded"])),
        .response(retryResponse(403, reasons: ["rateLimitExceeded", "insufficientPermissions"])),
        .response(retryResponse(429, after: "3600")), .network(.notConnectedToInternet), .network(.cancelled)]
    for failure in failures {
        let fixture = ReadRetryFixture([failure])
        await #expect(throws: (any Error).self) { try await retryReader(fixture).get("gmail.googleapis.com", ["fixture"]) }
        #expect(await fixture.requests.count == 1)
        #expect(await fixture.delays.isEmpty)
    }
}

@Test func googleReadRetryCancellationStopsBeforeAnotherAttempt() async throws {
    let fixture = ReadRetryFixture([.response(retryResponse(503))])
    let (enteredSleep, signal) = AsyncStream<Void>.makeStream()
    var reader = retryReader(fixture)
    reader.readRetry.sleep = { _ in
        signal.yield(); signal.finish()
        try await Task.sleep(for: .seconds(60))
    }
    let capturedReader = reader
    let operation = Task { try await capturedReader.get("gmail.googleapis.com", ["fixture"]) }
    for await _ in enteredSleep { break }
    operation.cancel()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(await fixture.requests.count == 1)

    let (transportStarted, startSignal) = AsyncStream<Void>.makeStream()
    let http = ConnectorHTTP { _ in
        startSignal.yield(); startSignal.finish()
        try? await Task.sleep(for: .seconds(60))
        return .init(data: Data(), status: 200) // A non-cooperative transport may return after cancellation.
    }
    let late = Task { try await GoogleReadRetry().send(URLRequest(url: URL(string: "https://gmail.googleapis.com/fixture")!), http: http) }
    for await _ in transportStarted { break }
    late.cancel()
    await #expect(throws: CancellationError.self) { try await late.value }
}

@Test func googleReadRetryCannotReplayWritesOrOtherServices() async throws {
    for method in ["POST", "PATCH", "DELETE"] {
        let fixture = ReadRetryFixture([.response(retryResponse(503))])
        let http = ConnectorHTTP { try await fixture.send($0) }
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = method
        await #expect(throws: (any Error).self) { try await http.send(request) }
        #expect(await fixture.requests.count == 1)
        await #expect(throws: (any Error).self) { try await GoogleReadRetry().send(request, http: http) }
        #expect(await fixture.requests.count == 1)
    }
    let denied = ConnectorHTTP { _ in Issue.record("An invalid retry request reached transport"); return .init(data: Data(), status: 200) }
    for url in ["https://slack.com/api/conversations.history", "http://gmail.googleapis.com/fixture"] {
        await #expect(throws: (any Error).self) { try await GoogleReadRetry().send(URLRequest(url: URL(string: url)!), http: denied) }
    }
    var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/fixture")!)
    request.httpBody = Data("body".utf8)
    await #expect(throws: (any Error).self) { try await GoogleReadRetry().send(request, http: denied) }
}
