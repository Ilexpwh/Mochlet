import Foundation
import Testing
@testable import SlimeCore

@Test func importedKnowledgePreservesUnknownMetadataAndUsesChosenScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("portable.md")
    let metadata = "provenance:\n  source: https://example.invalid/spec\n  verified: false\nx-custom:\n  - alpha\n  - beta"
    try ("---\ntype: Concept\ntitle: '部署規則'\nx-mochlet-scope: injected-other-project\n" + metadata + "\n---\n\nUse the staging environment.").write(to: source, atomically: true, encoding: .utf8)
    let vault = try KnowledgeVault(directory: root.appendingPathComponent("vault"))
    let id = try await vault.importDocument(source, scope: "chosen-project")
    #expect(try await vault.search("", scope: "injected-other-project").isEmpty)
    var note = try #require(try await vault.search("", scope: "chosen-project").first)
    #expect(note.id == id && note.title == "部署規則")
    #expect(try await vault.isCurrent(note))
    note.body += "\nCorrected by the user."
    try await vault.save(note, expectedRevision: note.revision)
    let markdown = try String(contentsOf: await vault.url(id), encoding: .utf8)
    let roundTrip = try PortableKnowledge(markdown)
    #expect(roundTrip.scalar("type") == "Concept")
    // YAML formatting may normalize; nested unknown metadata remains present.
    #expect(roundTrip.header.contains("source: https://example.invalid/spec") && roundTrip.header.contains("verified: false"))
    #expect(roundTrip.header.contains("x-custom:") && roundTrip.header.contains("- alpha") && roundTrip.header.contains("- beta"))
    #expect(try await !vault.isCurrent(note))
    let exported = try await vault.exportDocument(id, directory: root)
    #expect(try String(contentsOf: exported, encoding: .utf8) == markdown)
    await #expect(throws: (any Error).self) { try await vault.exportDocument(id, directory: root) }
}
