import Testing
import Foundation
@testable import SlimeCore

@Test func knowledgeScopesForgetAndRebuild() async throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:dir)}
    let vault=try KnowledgeVault(directory:dir)
    let a=KnowledgeNote(scope:"A",title:"Design",body:"mint slime 廣東話")
    let b=KnowledgeNote(scope:"B",title:"Private",body:"mint unrelated")
    let personal=KnowledgeNote(scope:"personal",title:"Preference",body:"mint")
    for n in [a,b,personal] {try await vault.save(n)}
    #expect(try await vault.search("mint",scope:"A").map(\.id) == [a.id])
    #expect(try await vault.search("mint",scope:"A",includePersonal:true).count == 2)
    try await vault.rebuild()
    #expect(try await vault.search("廣東話",scope:"A").count == 1)
    let noteURL = await vault.url(a.id)
    let before = try await vault.search("mint", scope: "A").first!.revision
    let text = try String(contentsOf: noteURL, encoding: .utf8)
    try text.replacingOccurrences(of: "mint slime 廣東話", with: "peach companion").write(to: noteURL, atomically: true, encoding: .utf8)
    #expect(try await vault.search("mint", scope: "A").isEmpty)
    #expect(try await vault.search("peach", scope: "A").first!.revision != before)
    try await vault.remove(a.id)
    #expect(try await vault.search("mint",scope:"A").isEmpty)
    #expect(try await vault.search("mint",scope:"B").count == 1)
}

@Test func memoryCorrectionsCheckRevisionAndForgetHistory() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let vault = try KnowledgeVault(directory: dir)
    let note = KnowledgeNote(scope: "personal", title: "Favorite", body: "Mint")
    try await vault.save(note)
    var edited = try await vault.search("", scope: "personal").first!
    let revision = edited.revision
    edited.body = "Lilac"
    try await vault.save(edited, expectedRevision: revision)
    await #expect(throws: (any Error).self) { try await vault.save(edited, expectedRevision: revision) }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("revisions/\(note.id)/\(revision).md").path))
    try await vault.remove(note.id)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("revisions/\(note.id)").path))
}
