import Foundation
import Testing
@testable import SlimeCore

private func organizationFixture() async throws -> (URL, URL, [FileExtraction], FileOrganizer) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let input = root.appendingPathComponent("inbox"), output = root.appendingPathComponent("organized")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try "Meeting notes".write(to: input.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
    try "Budget notes".write(to: input.appendingPathComponent("budget.txt"), atomically: true, encoding: .utf8)
    let files = try await FileIngestor().ingest([input]).files
    return (root, output, files, try FileOrganizer(folder: root))
}

@Test func organizationPreviewDoesNotCreateFoldersAndReviewedMovesUndo() async throws {
    let (root, output, files, organizer) = try await organizationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let proposal = FileOrganizationProposal.byFileType(files)
    let plan = try await organizer.previewOrganization(proposal, files: files, destination: output)
    #expect(plan.count == 2 && plan.allSatisfy { $0.state == "planned" && $0.reason != nil })
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    for move in plan { #expect(try await organizer.apply(id: move.id).state == "applied") }
    // Finder's /private/var spelling and the canonical /var spelling must still
    // match after rename so native attachment invalidation removes stale paths.
    for file in files {
        let canonical = FileOrganizer.canonicalPath(file.path)
        #expect(plan.contains { $0.source == canonical })
        if canonical.hasPrefix("/var/") { #expect(FileOrganizer.canonicalPath("/private" + canonical) == canonical) }
    }
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Documents/meeting.md").path))
    for move in plan.reversed() { #expect(try await organizer.apply(id: move.id, undo: true).state == "undone") }
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Documents").path).isEmpty)
}

@Test func organizationProposalRejectsUnknownIDsTraversalCollisionsAndPrefixConflicts() async throws {
    let (root, output, files, organizer) = try await organizationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    for path in ["../outside.txt", "/absolute.txt", "Hidden/.key", "foo\\bar", "a/./b", "a//b", "a:b", "~home/test"] {
        let proposal = FileOrganizationProposal(moves: [.init(fileID: files[0].id, destination: path, reason: "fixture")])
        await #expect(throws: (any Error).self) { try await organizer.previewOrganization(proposal, files: files, destination: output) }
    }
    for moves in [
        [FileOrganizationProposal.Item(fileID: "invented", destination: "a.txt", reason: "fixture")],
        [.init(fileID: files[0].id, destination: "a.txt", reason: "fixture"), .init(fileID: files[0].id, destination: "b.txt", reason: "fixture")],
        [.init(fileID: files[0].id, destination: "a.txt", reason: "fixture"), .init(fileID: files[1].id, destination: "A.txt", reason: "fixture")],
        [.init(fileID: files[0].id, destination: "folder", reason: "fixture"), .init(fileID: files[1].id, destination: "folder/file.txt", reason: "fixture")]
    ] {
        let response = String(decoding: try JSONEncoder().encode(FileOrganizationProposal(moves: moves)), as: UTF8.self)
        #expect(throws: (any Error).self) { try FileOrganizationProposal.decode(response, files: files) }
    }
    #expect(try await organizer.history().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
}

@Test func organizationRechecksReadRevisionDestinationIdentityAndSymlinkParents() async throws {
    let (root, output, files, organizer) = try await organizationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let plan = try await organizer.previewOrganization(.byFileType(files), files: files, destination: output)
    // Root replacement does not silently redirect an approved plan.
    try FileManager.default.moveItem(at: output, to: root.appendingPathComponent("old-destination"))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await organizer.apply(id: plan[0].id) }
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    let newPlan = try await organizer.previewOrganization(.byFileType(files), files: files, destination: output)
    try FileManager.default.createSymbolicLink(at: output.appendingPathComponent("Documents"), withDestinationURL: root.appendingPathComponent("inbox"))
    await #expect(throws: (any Error).self) { try await organizer.apply(id: newPlan[0].id) }
    try FileManager.default.removeItem(at: output.appendingPathComponent("Documents"))
    try "Changed since ingestion".write(to: URL(fileURLWithPath: files[0].path), atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await organizer.previewOrganization(.byFileType(files), files: files, destination: output) }
}

@Test func partialOrganizationRetainsEarlierSuccessForUndo() async throws {
    let (root, output, files, organizer) = try await organizationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let plan = try await organizer.previewOrganization(.byFileType(files), files: files, destination: output)
    _ = try await organizer.apply(id: plan[0].id)
    try "Changed second source".write(to: URL(fileURLWithPath: plan[1].source), atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await organizer.apply(id: plan[1].id) }
    let reopened = try FileOrganizer(folder: root); try await reopened.reconcile()
    #expect(try await reopened.history().contains { $0.id == plan[0].id && $0.state == "applied" })
    #expect(try await reopened.apply(id: plan[0].id, undo: true).state == "undone")
    #expect(try String(contentsOf: URL(fileURLWithPath: plan[1].source), encoding: .utf8) == "Changed second source")
}
