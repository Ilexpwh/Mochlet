import Foundation
import CryptoKit
import GRDB

public struct MeetingSegment: Codable, Identifiable, Sendable {
    public var id: String
    public var source: String
    public var offset: Double
    public var duration: Double
    public var recordedAt: Date
    public var audioAvailable: Bool = true
    public var transcript: AudioTranscript?
    public var error: String?
}
public struct MeetingTranscriptRevision: Codable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var final: Bool
    public var part: Int
    public var offset: Double
    public var transcript: AudioTranscript
    public init(id: String = UUID().uuidString, final: Bool, part: Int, offset: Double, transcript: AudioTranscript) {
        self.id = id; self.createdAt = Date(); self.final = final; self.part = part; self.offset = offset; self.transcript = transcript
    }
}
public struct MeetingSession: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var projectID: String?
    public var startedAt = Date()
    public var state = "recording"
    public var source: String
    public var modelID: String
    public var keepAudio = false
    public var segments: [MeetingSegment] = []
    public var revisions: [MeetingTranscriptRevision] = []
    public var speakerNames: [String: String] = [:]
    public var notes: String?
    public var notices: [String] = []
    public init(title: String, projectID: String?, source: String, modelID: String) {
        self.title = title; self.projectID = projectID; self.source = source; self.modelID = modelID
    }
}

public actor MeetingStore {
    private let db: DatabaseQueue
    private let directory: URL
    private var key: SymmetricKey?
    public init(directory: URL, keyData: Data? = nil) throws {
        guard keyData == nil || keyData?.count == 32 else { throw MochletError.message("The meeting encryption key is invalid.") }
        self.directory = directory; key = keyData.map { SymmetricKey(data: $0) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try DatabaseQueue(path: directory.appendingPathComponent("meetings.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("meeting-v1") { db in
            try db.execute(sql: "CREATE TABLE meetings(id TEXT PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE meeting_events(id INTEGER PRIMARY KEY,meetingID TEXT NOT NULL,kind TEXT NOT NULL,createdAt DOUBLE NOT NULL);")
        }
        try migrator.migrate(db)
    }
    public func setKey(_ data: Data) throws {
        guard data.count == 32 else { throw MochletError.message("Invalid audio encryption key.") }; key = SymmetricKey(data: data)
    }
    public func all() throws -> [MeetingSession] {
        try db.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM meetings").map { try JSONDecoder().decode(MeetingSession.self, from: $0) }.sorted { $0.startedAt > $1.startedAt } }
    }
    public func create(_ meeting: MeetingSession) throws {
        let data = try JSONEncoder().encode(meeting)
        try db.write { db in try db.execute(sql: "INSERT INTO meetings(id,payload) VALUES(?,?)", arguments: [meeting.id,data]) }
    }
    public func update(_ id: String, event: String, change: @Sendable (inout MeetingSession) throws -> Void) throws {
        try db.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM meetings WHERE id=?", arguments: [id]) else { throw MochletError.message("Meeting no longer exists.") }
            var value = try JSONDecoder().decode(MeetingSession.self, from: data); try change(&value)
            try db.execute(sql: "UPDATE meetings SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(value), id])
            try db.execute(sql: "INSERT INTO meeting_events(meetingID,kind,createdAt) VALUES(?,?,?)", arguments: [id,event,Date().timeIntervalSince1970])
        }
    }
    private func audioURL(meetingID: String, segmentID: String) throws -> URL {
        guard UUID(uuidString: meetingID) != nil, UUID(uuidString: segmentID) != nil else { throw MochletError.message("Invalid recording identity.") }
        return directory.appendingPathComponent(meetingID).appendingPathComponent(segmentID + ".aesgcm")
    }
    public func appendAudio(meetingID: String, source: String, offset: Double, duration: Double, wav: Data, recordedAt: Date = Date()) throws -> MeetingSegment {
        guard let key else { throw MochletError.message("Meeting audio key is unavailable.") }
        guard offset.isFinite, offset >= 0, duration.isFinite, duration > 0, wav.count <= 20_000_000 else { throw MochletError.message("Invalid or oversized audio segment.") }
        let segment = MeetingSegment(id: UUID().uuidString, source: source, offset: offset, duration: duration, recordedAt: recordedAt)
        let url = try audioURL(meetingID: meetingID, segmentID: segment.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let associated = Data("\(meetingID):\(segment.id)".utf8)
        guard let encrypted = try AES.GCM.seal(wav, using: key, authenticating: associated).combined else { throw MochletError.message("Audio encryption failed.") }
        try encrypted.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: recordedAt], ofItemAtPath: url.path)
        do { try update(meetingID, event: "audio-segment") { $0.segments.append(segment) } }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return segment
    }
    public func audio(meetingID: String, segmentID: String) throws -> Data {
        guard let key else { throw MochletError.message("Meeting audio key is unavailable.") }
        let data = try Data(contentsOf: audioURL(meetingID: meetingID, segmentID: segmentID))
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data("\(meetingID):\(segmentID)".utf8))
    }
    public func deleteAudio(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw MochletError.message("Invalid recording identity.") }
        guard try all().contains(where: { $0.id == id }) else { return }
        // Delete the whole validated session directory, including ciphertext written
        // immediately before a crash prevented its manifest transaction.
        let audioDirectory = directory.appendingPathComponent(id, isDirectory: true)
        if (try? FileManager.default.attributesOfItem(atPath: audioDirectory.path)) != nil {
            try FileManager.default.removeItem(at: audioDirectory)
        }
        try update(id, event: "audio-deleted") { value in for index in value.segments.indices { value.segments[index].audioAvailable = false } }
    }
    public func delete(_ id: String) throws {
        try deleteAudio(id)
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id=?", arguments: [id])
            try db.execute(sql: "DELETE FROM meeting_events WHERE meetingID=?", arguments: [id])
        }
    }
    public func sweep(now: Date = Date()) throws {
        try sweepOrphans(now: now)
        for meeting in try all() where !meeting.keepAudio {
            let expired = meeting.segments.filter { $0.audioAvailable && now.timeIntervalSince($0.recordedAt) >= 7 * 86400 }
            for segment in expired {
                let url = try audioURL(meetingID: meeting.id, segmentID: segment.id)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            let ids = Set(expired.map(\.id))
            if !ids.isEmpty { try update(meeting.id, event: "retention") { value in for index in value.segments.indices where ids.contains(value.segments[index].id) { value.segments[index].audioAvailable = false } } }
        }
    }
    private func sweepOrphans(now: Date) throws {
        let meetings = try all()
        let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let meeting = meetings.first { $0.id == folder.lastPathComponent }
            guard meeting?.keepAudio != true else { continue }
            let known = Set(meeting?.segments.map { $0.id + ".aesgcm" } ?? [])
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) where file.pathExtension == "aesgcm" && !known.contains(file.lastPathComponent) {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, let date = values.contentModificationDate, now.timeIntervalSince(date) >= 7 * 86400 else { continue }
                try FileManager.default.removeItem(at: file)
            }
        }
    }
    public func recover() throws {
        for meeting in try all() where ["recording", "pausing", "processing"].contains(meeting.state) {
            try update(meeting.id, event: "recovered") { $0.state = "interrupted"; $0.notices.append("Recording or processing was interrupted. Saved segments are recoverable; resume and reprocessing require an explicit action.") }
        }
        try sweep()
    }
}

public enum MeetingAudioPlan {
    public static func finalSegments(_ meeting: MeetingSession) throws -> [MeetingSegment] {
        // Source tracks are authoritative. A crash may have saved them before the
        // derivative mix; final assembly must not omit those recoverable samples.
        let originals = meeting.segments.filter { $0.source != "mix" }
        let segments = (originals.isEmpty ? meeting.segments : originals).sorted { $0.offset < $1.offset }
        guard !segments.isEmpty else { throw MochletError.message("No recoverable audio was recorded.") }
        guard segments.allSatisfy(\.audioAvailable) else {
            throw MochletError.message("Some recording audio has expired or been deleted. Provisional text remains available; finalization cannot recreate missing audio.")
        }
        return segments
    }
}

public enum PCM16WAV {
    public static func encode(_ samples: [Float], sampleRate: UInt32 = 16000) -> Data {
        var data = Data()
        func string(_ value: String) { data.append(Data(value.utf8)) }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        let size = UInt32(samples.count * 2)
        string("RIFF"); u32(size + 36); string("WAVEfmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16); string("data"); u32(size)
        for sample in samples { let finite = sample.isFinite ? sample : 0; u16(UInt16(bitPattern: Int16(max(-1, min(1, finite)) * 32767))) }
        return data
    }
}
