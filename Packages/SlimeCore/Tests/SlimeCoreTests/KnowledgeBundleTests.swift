import Foundation
import Testing
@testable import SlimeCore

private func bundleFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("input/guides"), withIntermediateDirectories: true)
    return root
}
private func writeConcept(_ root: URL, _ relative: String, _ text: String) throws {
    try text.write(to: root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
}

@Test func bundleSnapshotRoundTripKeepsPathsAndForgettingRemovesExportedContent() async throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    try writeConcept(root, "input/index.md", "# Navigation")
    try writeConcept(root, "input/log.md", "# History")
    try writeConcept(root, "input/guides/alpha.md", "---\n\"type\": Custom Future Type\n\"title\": Alpha\nx-unknown: { nested: [one, two] }\nverified: { by: 'human:fixture', at: 2026-11-01T00:00:00Z }\n---\n\nSee [Beta](../beta.md) and [root](/beta.md).")
    try writeConcept(root, "input/beta.md", "---\ntype: Note\nx-mochlet-scope: wrong\n---\n\nPrivate forgotten fact.")
    try writeConcept(root, "input/image.png", "not real image")
    let preview = try KnowledgeBundle.preview(directory: root.appendingPathComponent("input"), scope: "project-one")
    #expect(preview.concepts.count == 2 && preview.notices.count == 3)
    // Changing the source after review cannot substitute new content into this import.
    try writeConcept(root, "input/beta.md", "---\ntype: Note\n---\n\nUnreviewed replacement.")
    let vault = try KnowledgeVault(directory: root.appendingPathComponent("vault"))
    #expect(try await vault.importBundle(preview) == 2)
    await #expect(throws: (any Error).self) { try await vault.importBundle(preview) }
    #expect(try await vault.search("", scope: "wrong").isEmpty)
    let notes = try await vault.search("", scope: "project-one")
    let beta = try #require(notes.first { $0.title == "beta" })
    #expect(beta.body == "Private forgotten fact.")
    let output = try await vault.exportScope("project-one", to: root)
    let bundle = output.appendingPathComponent("bundles/" + preview.id)
    let alpha = try PortableKnowledge(String(contentsOf: bundle.appendingPathComponent("guides/alpha.md"), encoding: .utf8))
    #expect(alpha.header.contains("x-unknown") && alpha.header.contains("verified"))
    #expect(alpha.body.contains("../beta.md") && alpha.body.contains("/beta.md"))
    #expect(try KnowledgeBundle.preview(directory: bundle, scope: "second").concepts.count == 2)
    #expect(throws: (any Error).self) { try KnowledgeBundle.preview(directory: output, scope: "second") }
    try await vault.remove(beta.id)
    let after = try await vault.exportScope("project-one", to: root)
    #expect(!FileManager.default.fileExists(atPath: after.appendingPathComponent("bundles/" + preview.id + "/beta.md").path))
    #expect(!FileManager.default.fileExists(atPath: after.appendingPathComponent("bundles/" + preview.id + "/image.png").path))
}

@Test func bundleRejectsMalformedMetadataAndNeverFollowsLinks() throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    try writeConcept(root, "secret.md", "---\ntype: Note\n---\n\nOutside")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("input/secret.md"), withDestinationURL: root.appendingPathComponent("secret.md"))
    try writeConcept(root, "input/valid.md", "---\ntype: Note\n---\n\nInside")
    let result = try KnowledgeBundle.preview(directory: root.appendingPathComponent("input"), scope: "personal")
    #expect(result.concepts.count == 1 && result.notices.contains { $0.contains("symbolic") })
    for yaml in ["type: Note\ntype: Injected", "type: null", "type: []", "type: ''", "type: Note\nx: [", "type: Note\nx: &a [one]\ny: *a", "type: Note\nx: [&a [one],&b [*a,*a],&c [*b,*b],&d [*c,*c]]"] {
        try writeConcept(root, "input/valid.md", "---\n" + yaml + "\n---\n\nBody")
        #expect(throws: (any Error).self) { try KnowledgeBundle.preview(directory: root.appendingPathComponent("input"), scope: "personal") }
    }
    #expect(throws: (any Error).self) { try PortableKnowledge("---\n---\n") }
}

@Test func memoryLifecycleExcludesExpiredDraftAndDeprecatedEvidence() async throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let vault = try KnowledgeVault(directory: root.appendingPathComponent("vault"))
    for (name, metadata) in [("draft", "status: draft"), ("old", "status: deprecated"), ("stale", "stale_after: 2000-01-01T00:00:00Z"), ("bad", "stale_after: tomorrow"), ("future", "stale_after: '2100-01-01T00:00:00Z'"), ("plain", "x-extra: custom")] {
        let source = root.appendingPathComponent(name + ".md")
        try ("---\ntype: Note\n" + metadata + "\n---\n\nFixture memory").write(to: source, atomically: true, encoding: .utf8)
        _ = try await vault.importDocument(source, scope: "personal")
    }
    #expect(try await vault.search("", scope: "personal").count == 2)
    let all = try await vault.search("", scope: "personal", includeUnavailable: true)
    #expect(all.count == 6)
    let stale = try #require(all.first { $0.title == "stale" })
    #expect(try await !vault.isCurrent(stale))
    try await vault.reviewLifecycle(stale, status: "stable", staleAfter: nil)
    #expect(try await vault.search("", scope: "personal").count == 3)
    await #expect(throws: (any Error).self) { try await vault.reviewLifecycle(stale, status: "stable", staleAfter: nil) }
    let updated = try #require(try await vault.search("", scope: "personal").first { $0.id == stale.id })
    let expiredDocument = try PortableKnowledge(String(contentsOf: await vault.url(updated.id), encoding: .utf8))
    try expiredDocument.replacing(["stale_after": "2000-01-01T00:00:00Z"]).write(to: await vault.url(updated.id), atomically: true, encoding: .utf8)
    #expect(try await !vault.isCurrent(updated))
}

@Test func interruptedBundleImportRollsBackOnlyJournaledNewNotes() async throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("vault")
    let vault = try KnowledgeVault(directory: directory)
    let original = KnowledgeNote(scope: "personal", title: "Keep", body: "Original")
    try await vault.save(original)
    let partial = UUID().uuidString
    try "partial new import".write(to: directory.appendingPathComponent(partial + ".md"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode([partial]).write(to: directory.appendingPathComponent("pending-import.json"))
    let reopened = try KnowledgeVault(directory: directory)
    #expect(try await reopened.search("", scope: "personal").map(\.id) == [original.id])
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(partial + ".md").path))
}

@Test func malformedConnectedMetadataCannotBecomeIndependentMemory() async throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    try writeConcept(root, "input/connected.md", "---\ntype: Note\nx-mochlet-connection: {malformed: value}\n---\n\nDo not promote to unbound evidence.")
    let vault = try KnowledgeVault(directory: root.appendingPathComponent("vault"))
    _ = try await vault.importDocument(root.appendingPathComponent("input/connected.md"), scope: "personal")
    #expect(try await vault.search("", scope: "personal").isEmpty)
    #expect(try await vault.search("", scope: "personal", includeUnavailable: true).count == 1)
}

@Test func excludedNewerNotesDoNotConsumeRetrievalLimit() async throws {
    let root = try bundleFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let vault = try KnowledgeVault(directory: root.appendingPathComponent("vault"))
    let eligible = KnowledgeNote(scope: "personal", title: "Eligible", body: "matched source")
    try await vault.save(eligible)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: await vault.url(eligible.id).path)
    for index in 0..<6 {
        let source = root.appendingPathComponent("draft-\(index).md")
        try "---\ntype: Note\nstatus: draft\n---\n\nmatched source".write(to: source, atomically: true, encoding: .utf8)
        _ = try await vault.importDocument(source, scope: "personal")
    }
    #expect(try await vault.search("matched", scope: "personal", limit: 1).map(\.id) == [eligible.id])
    #expect(try await vault.search("matched", scope: "personal", limit: 1, includeUnavailable: true).first?.eligibilityReason != nil)
}
