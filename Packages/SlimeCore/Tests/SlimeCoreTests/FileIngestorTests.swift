import Testing
import Foundation
@testable import SlimeCore

@Test func ingestionLabelsSourcesAndReportsUnsupportedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = root.appendingPathComponent("notes.md")
    try "Mint\n廣東話".write(to: text, atomically: true, encoding: .utf8)
    try Data([0,1,2]).write(to: root.appendingPathComponent("unknown.bin"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.md"), withDestinationURL: text)
    let result = try await FileIngestor().ingest([root, text])
    #expect(result.files.count == 1)
    #expect(result.files[0].text.contains("[Line 2] 廣東話"))
    #expect(result.files[0].revision.count == 64)
    #expect(result.failures.contains { $0.contains("Unsupported") })
}
