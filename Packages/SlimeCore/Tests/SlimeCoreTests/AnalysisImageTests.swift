import Foundation
import Testing
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import SlimeCore

private func fictionalImage(width: Int = 24, height: Int = 16) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.5, green: 0.9, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private metadata"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func imageWithoutOCRRemainsAvailableAndPreparationPinsRevision() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mint.png")
    let bytes = try fictionalImage(); try bytes.write(to: url)
    let result = try await FileIngestor().ingest([url])
    let file = try #require(result.files.first)
    #expect(file.kind == "Image OCR")
    #expect(file.text.contains("No readable OCR"))
    let prepared = try await AnalysisImagePreparer().prepare([file])
    #expect(prepared.count == 1)
    #expect(prepared[0].sourceID == file.id)
    let source = try #require(CGImageSourceCreateWithData(prepared[0].jpeg as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    #expect((properties[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] == nil)
    #expect(properties[kCGImagePropertyGPSDictionary as String] == nil)
    #expect((properties[kCGImagePropertyPixelWidth as String] as? Int) ?? 9999 <= 2048)
    try Data("changed".utf8).write(to: url)
    await #expect(throws: (any Error).self) { try await AnalysisImagePreparer().prepare([file]) }
    try FileManager.default.removeItem(at: url)
    let other = root.appendingPathComponent("other.png"); try bytes.write(to: other)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
    await #expect(throws: (any Error).self) { try await AnalysisImagePreparer().prepare([file]) }
}

@Test func imageRequestPinsIdentityAndDisablesFallbacks() throws {
    let image = try AnalysisImage(sourceID: "file-a", jpeg: Data([0xff, 0xd8, 0xff, 1]))
    let body = try OpenRouterService.imageRequest(prompt: "Cite sources", images: [image], model: "vision")
    let parts = try #require(body["messages"].array.first?["content"].array)
    #expect(parts[0]["text"].string == "Cite sources")
    #expect(parts[1]["text"].string?.contains("file-a") == true)
    #expect(parts[2]["image_url"]["url"].string == "data:image/jpeg;base64,/9j/AQ==")
    #expect(body["provider"]["allow_fallbacks"] == .bool(false))
    #expect(throws: (any Error).self) { try OpenRouterService.imageRequest(prompt: "", images: [image, image], model: "vision") }
    #expect(throws: (any Error).self) { try AnalysisImage(sourceID: "", jpeg: Data([0xff, 0xd8, 0xff])) }
    #expect(throws: (any Error).self) { try AnalysisImage(sourceID: "a", jpeg: Data(repeating: 1, count: 4_000_001)) }
}

private final class VisionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // A request from the unsupported-model path must never arrive here.
        let valid = request.url?.path == "/api/v1/chat/completions" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fictional"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"VISION_FIXTURE_OK"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test func visionServiceRequiresCapabilitiesAndReadsProviderResult() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [VisionURLProtocol.self]
    let service = OpenRouterService(session: URLSession(configuration: config))
    let image = try AnalysisImage(sourceID: "fixture", jpeg: Data([0xff, 0xd8, 0xff, 1]))
    let vision = ModelDescriptor(id: "fixture", name: "Vision", inputModalities: ["text", "image"], outputModalities: ["text"])
    #expect(try await service.analyze(prompt: "Describe", images: [image], model: vision, key: "fictional") == "VISION_FIXTURE_OK")
    let text = ModelDescriptor(id: "text-only", name: "Text", inputModalities: ["text"], outputModalities: ["text"])
    await #expect(throws: (any Error).self) { try await service.analyze(prompt: "Describe", images: [image], model: text, key: "fictional") }
}

@Test func encodedImageBoundsAreCheckedBeforeOCRAndThumbnailDecode() async throws {
    let oversized = try fictionalImage(width: 8193, height: 1)
    #expect(oversized.count < 5_000_000)
    #expect(throws: (any Error).self) { try ImageInputValidation.source(oversized) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("wide.png"); try oversized.write(to: url)
    let result = try await FileIngestor().ingest([url])
    #expect(result.files.isEmpty)
    #expect(result.failures.contains { $0.contains("decoding limit") })
}
