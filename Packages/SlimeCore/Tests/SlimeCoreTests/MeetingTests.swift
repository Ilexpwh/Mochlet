import Foundation
import Testing
@testable import SlimeCore

@Test func meetingAudioIsEncryptedRecoverableAndExpiresFromRecording() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(directory: root, keyData: Data(repeating: 7, count: 32))
    let meeting = MeetingSession(title: "Fixture", projectID: nil, source: "microphone", modelID: "fixture")
    try await store.create(meeting)
    let wav = PCM16WAV.encode([0, 0.5, -0.5, .nan])
    let segment = try await store.appendAudio(meetingID: meeting.id, source: "microphone", offset: 0, duration: 1, wav: wav, recordedAt: Date(timeIntervalSince1970: 100))
    #expect(try await store.audio(meetingID: meeting.id, segmentID: segment.id) == wav)
    let encrypted = try Data(contentsOf: root.appendingPathComponent(meeting.id).appendingPathComponent(segment.id + ".aesgcm"))
    #expect(encrypted != wav)
    try await store.recover()
    #expect(try await store.all().first?.state == "interrupted")
    #expect(try await store.all().first?.segments.first?.audioAvailable == false)
    await #expect(throws: (any Error).self) { try await store.audio(meetingID: meeting.id, segmentID: segment.id) }
}

@Test func keptMeetingAudioSurvivesSweepAndTranscriptsReplaceByIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(directory: root, keyData: Data(repeating: 3, count: 32))
    var meeting = MeetingSession(title: "Kept", projectID: nil, source: "microphone", modelID: "fixture")
    meeting.keepAudio = true
    try await store.create(meeting)
    let segment = try await store.appendAudio(meetingID: meeting.id, source: "microphone", offset: 0, duration: 1, wav: PCM16WAV.encode([0]), recordedAt: .distantPast)
    try await store.sweep()
    #expect(try await store.all().first?.segments.first?.audioAvailable == true)
    try await store.deleteAudio(meeting.id)
    #expect(try await store.all().first?.segments.first?.id == segment.id)
    #expect(try await store.all().first?.segments.first?.audioAvailable == false)
}

@Test func audioAssemblyPreservesOffsetsAndBoundsPartSize() throws {
    let a = AudioSlice(offset: 0, samples: [Float](repeating: 0.5, count: 16000))
    let b = AudioSlice(offset: 0.5, samples: [Float](repeating: -0.5, count: 16000))
    let mix = try AudioAssembly.mix([a,b], offset: 0, duration: 2)
    #expect(mix[0] == 0.5)
    #expect(mix[8000] == 0)
    #expect(mix[16000] == -0.5)
    #expect(mix[24000] == 0)
    #expect(try AudioAssembly.decode(PCM16WAV.encode(mix)).count == 32000)
    #expect(throws: (any Error).self) { try AudioAssembly.mix([a], offset: 0, duration: 301) }
}

@Test func finalTranscriptReplacementIsAtomicAndPreservesSpeakerCorrections() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(directory: root)
    let meeting = MeetingSession(title: "Transcript", projectID: "P", source: "microphone", modelID: "fixture")
    try await store.create(meeting)
    let transcript = try AudioTranscript.decode(Data("{\"text\":\"Hello\",\"segments\":[{\"start\":0,\"end\":1,\"text\":\"Hello\",\"speaker\":\"1\"}]}".utf8), requestID: "request-a")
    let revision = MeetingTranscriptRevision(final: true, part: 0, offset: 0, transcript: transcript)
    try await store.update(meeting.id, event: "final") { $0.revisions.append(revision); $0.speakerNames["request-a:1"] = "Alex" }
    await #expect(throws: (any Error).self) {
        try await store.update(meeting.id, event: "failed-replacement") { $0.revisions = []; throw MochletError.message("Fixture failure") }
    }
    #expect(try await store.all().first?.revisions.count == 1)
    #expect(try await store.all().first?.speakerNames["request-a:1"] == "Alex")
}

@Test func orphanAudioExpiresAfterInterruptedMetadataCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(directory: root)
    let folder = root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let orphan = folder.appendingPathComponent(UUID().uuidString + ".aesgcm")
    try Data([1,2,3]).write(to: orphan)
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: orphan.path)
    try await store.sweep()
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}
