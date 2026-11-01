import Foundation
import GRDB
import Testing
@testable import SlimeCore

@Test func reviewedFileMovesRejectConflictsAndChangedFilesAndUndoSafely() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("organized")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let organizer = try FileOrganizer(folder: root)
    let source = root.appendingPathComponent("note.md")
    try "original".write(to: source, atomically: true, encoding: .utf8)
    let first = try #require(try await organizer.preview(paths: [source.path], destination: destination).first)
    try "changed".write(to: source, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await organizer.apply(id: first.id) }
    let second = try #require(try await organizer.preview(paths: [source.path], destination: destination).first)
    let moved = try await organizer.apply(id: second.id)
    #expect(moved.state == "applied" && !FileManager.default.fileExists(atPath: source.path))
    try "new original path occupant".write(to: source, atomically: true, encoding: .utf8)
    await #expect(throws: (any Error).self) { try await organizer.apply(id: second.id, undo: true) }
    #expect(try String(contentsOf: source, encoding: .utf8) == "new original path occupant")
    try FileManager.default.removeItem(at: source)
    #expect(try await organizer.apply(id: second.id, undo: true).state == "undone")
    #expect(try String(contentsOf: source, encoding: .utf8) == "changed")
    await #expect(throws: (any Error).self) { try await organizer.apply(id: second.id, undo: true) }
    let symlink = root.appendingPathComponent("link.md")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
    await #expect(throws: (any Error).self) { try await organizer.preview(paths: [symlink.path], destination: destination) }
}

@Test func interruptedFileMoveReconcilesWithoutRepeatingRename() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("organized")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note.md")
    try "content".write(to: source, atomically: true, encoding: .utf8)
    let organizer = try FileOrganizer(folder: root)
    var move = try #require(try await organizer.preview(paths: [source.path], destination: destination).first)
    move.state = "applying"
    let payload = try JSONEncoder().encode(move)
    let id = move.id
    let db = try DatabaseQueue(path: root.appendingPathComponent("file-operations.sqlite").path)
    try await db.write { try $0.execute(sql: "UPDATE file_moves SET payload=? WHERE id=?", arguments: [payload, id]) }
    try FileManager.default.moveItem(atPath: move.source, toPath: move.destination)
    try await organizer.reconcile()
    #expect(try await organizer.history().first?.state == "applied")
    await #expect(throws: (any Error).self) { try await organizer.apply(id: id) }
    #expect(try await organizer.apply(id: id, undo: true).state == "undone")
}

@Test func olderFileMovesRemainReachableThroughHistoryPages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = root.appendingPathComponent("organized")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note.md")
    try "content".write(to: source, atomically: true, encoding: .utf8)
    let organizer = try FileOrganizer(folder: root)
    let first = try #require(try await organizer.preview(paths: [source.path], destination: destination).first)
    for _ in 0..<15 { _ = try await organizer.preview(paths: [source.path], destination: destination) }
    _ = try await organizer.apply(id: first.id)
    let firstPage = try await organizer.history(limit: 10)
    let secondPage = try await organizer.history(limit: 10, offset: 10)
    #expect(firstPage.count == 10 && secondPage.contains { $0.id == first.id && $0.state == "applied" })
    _ = try await organizer.apply(id: first.id, undo: true)
}
