import Foundation
import Testing
@testable import SlimeCore

@Test func diarizationLabelsAreRequestScopedAndUseWordLabels() throws {
    let fixture = Data(#"{"text":"Hello again","segments":[{"start":0,"end":2,"text":"Hello again"}],"words":[{"start":0,"end":1,"word":"Hello","speaker":1},{"start":1,"end":2,"word":"again","speaker_label":"1"}]}"#.utf8)
    let a = try AudioTranscript.decode(fixture, requestID: "part-a")
    let b = try AudioTranscript.decode(fixture, requestID: "part-b")
    #expect(a.hasSpeakerLabels)
    #expect(a.spans.count == 2)
    #expect(a.spans[0].speaker != b.spans[0].speaker)
    #expect(throws: (any Error).self) { try AudioTranscript.decode(Data("{}".utf8), requestID: "bad") }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let forbidden = request.value(forHTTPHeaderField: "Authorization") == "Bearer rejected"
        let status = forbidden ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((forbidden ? "{}" : #"{"text":"廣東話 Mandarin English","segments":[]}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func transcriptionHandlesAuthenticationAndTextOnlyResponses() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelURLProtocol.self]
    let service = OpenRouterService(session: URLSession(configuration: config))
    let result = try await service.transcribe(audio: Data([1]), format: "wav", model: "fixture", key: "test", diarize: false, requestID: "test")
    #expect(result.text.contains("廣東話"))
    #expect(!result.hasSpeakerLabels)
    await #expect(throws: (any Error).self) { try await service.transcribe(audio: Data([1]), format: "wav", model: "fixture", key: "rejected", diarize: true, requestID: "test") }
    await #expect(throws: (any Error).self) { try await service.transcribe(audio: Data(), format: "wav", model: "fixture", key: "test", diarize: false, requestID: "empty") }
}
