import Foundation

public struct ModelDescriptor: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var inputModalities: [String]
    public var outputModalities: [String]
}
public struct TranscriptSpan: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?
}
public struct AudioTranscript: Codable, Sendable, Equatable {
    public var requestID: String
    public var text: String
    public var spans: [TranscriptSpan]
    public var hasSpeakerLabels: Bool { spans.contains { $0.speaker != nil } }
    public static func decode(_ data: Data, requestID: String) throws -> Self {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let text = json["text"].string else { throw MochletError.message("Transcription response did not contain text.") }
        let words = json["words"].array
        let hasWordSpeakers = words.contains { $0["speaker"] != .null || $0["speaker_label"] != .null }
        let entries = hasWordSpeakers ? words : json["segments"].array
        var spans: [TranscriptSpan] = []
        for (index, entry) in entries.enumerated() {
            guard let start = entry["start"].number, let end = entry["end"].number,
                  start.isFinite, end.isFinite, start >= 0, end >= start,
                  let content = entry[hasWordSpeakers ? "word" : "text"].string else { continue }
            let speaker = entry["speaker_label"].string ?? entry["speaker"].string ?? entry["speaker"].number.map { String($0) }
            spans.append(.init(id: "\(requestID):\(index)", start: start, end: end, text: content, speaker: speaker.map { "\(requestID):\($0)" }))
        }
        return .init(requestID: requestID, text: text, spans: spans)
    }
}
public protocol ModelService: Sendable {
    func models(transcription: Bool) async throws -> [ModelDescriptor]
    func transcribe(audio: Data, format: String, model: String, key: String, diarize: Bool, requestID: String) async throws -> AudioTranscript
    func answer(prompt: String, model: String, key: String) async throws -> String
    func analyze(prompt: String, images: [AnalysisImage], model: ModelDescriptor, key: String) async throws -> String
}

public actor OpenRouterService: ModelService {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func models(transcription: Bool) async throws -> [ModelDescriptor] {
        let url = URL(string: "https://openrouter.ai/api/v1/models" + (transcription ? "?output_modalities=transcription" : ""))!
        let data = try await send(URLRequest(url: url))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        return json["data"].array.compactMap { row in
            guard let id = row["id"].string else { return nil }
            return ModelDescriptor(id: id, name: row["name"].string ?? id,
                                   inputModalities: row["architecture"]["input_modalities"].array.compactMap(\.string),
                                   outputModalities: row["architecture"]["output_modalities"].array.compactMap(\.string))
        }
    }
    public func transcribe(audio: Data, format: String, model: String, key: String, diarize: Bool, requestID: String = UUID().uuidString) async throws -> AudioTranscript {
        guard !audio.isEmpty, audio.count <= 20_000_000 else { throw MochletError.message("This recording is empty or exceeds Mochlet's 20 MB request limit. Process it as explicit parts.") }
        var body: [String: JSONValue] = ["model": .string(model), "input_audio": .object(["data": .string(audio.base64EncodedString()), "format": .string(format)]), "response_format": .string(diarize ? "verbose_json" : "json"), "provider": .object(["allow_fallbacks": .bool(false)])]
        if diarize { body["diarize"] = .bool(true); body["timestamp_granularities"] = .array([.string("word"), .string("segment")]) }
        let data = try await post("audio/transcriptions", body: .object(body), key: key)
        return try AudioTranscript.decode(data, requestID: requestID)
    }
    public func answer(prompt: String, model: String, key: String) async throws -> String {
        let body: JSONValue = .object(["model": .string(model), "messages": .array([.object(["role": .string("user"), "content": .string(prompt)])]), "provider": .object(["allow_fallbacks": .bool(false)])])
        let data = try await post("chat/completions", body: body, key: key)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let text = json["choices"].array.first?["message"]["content"].string else { throw MochletError.message("The selected model returned no text answer.") }
        return text
    }
    public func analyze(prompt: String, images: [AnalysisImage], model: ModelDescriptor, key: String) async throws -> String {
        guard !images.isEmpty else { return try await answer(prompt: prompt, model: model.id, key: key) }
        guard model.inputModalities.contains("image"), model.outputModalities.contains("text") else {
            throw MochletError.message("Choose an available image-input, text-output analysis model in Speech & Models. No images were sent.")
        }
        let body = try Self.imageRequest(prompt: prompt, images: images, model: model.id)
        try Task.checkCancellation()
        let data = try await post("chat/completions", body: body, key: key)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let text = json["choices"].array.first?["message"]["content"].string else { throw MochletError.message("The selected model returned no text answer.") }
        return text
    }
    static func imageRequest(prompt: String, images: [AnalysisImage], model: String) throws -> JSONValue {
        guard images.count <= 6, Set(images.map(\.sourceID)).count == images.count,
              images.reduce(0, { $0 + $1.jpeg.count }) <= 12_000_000 else {
            throw MochletError.message("Image analysis accepts six distinct images and 12 MB of prepared image bytes at most.")
        }
        var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(prompt)])]
        for image in images {
            content.append(.object(["type": .string("text"), "text": .string("Image for evidence source ID: " + image.sourceID)]))
            content.append(.object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/jpeg;base64," + image.jpeg.base64EncodedString())])]))
        }
        return .object(["model": .string(model), "messages": .array([.object(["role": .string("user"), "content": .array(content)])]), "provider": .object(["allow_fallbacks": .bool(false)])])
    }
    private func post(_ path: String, body: JSONValue, key: String) async throws -> Data {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MochletError.message("Add your OpenRouter key in Speech & Models.") }
        guard let model = body["model"].string, !model.isEmpty else { throw MochletError.message("Choose a model in Speech & Models first.") }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/\(path)")!)
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MochletError.message("No HTTP response from OpenRouter.") }
        guard (200..<300).contains(http.statusCode) else { throw MochletError.message("OpenRouter returned HTTP \(http.statusCode). Check the selected model's capabilities, key and balance. No fallback was attempted.") }
        guard data.count <= 24_000_000 else { throw MochletError.message("The provider response exceeded the local size limit.") }
        return data
    }
}
