import Foundation

/// A stretch of recognised speech with its place in the audio (seconds).
public struct TimedPhrase: Sendable, Equatable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Someone in a call. You are always "me"; the others are "p2", "p3"… until renamed.
public struct MeetingSpeaker: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isMe: Bool
    public init(id: String, name: String, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.isMe = isMe
    }
}

/// One turn of speech, seconds from the start of the recording.
public struct MeetingLine: Codable, Equatable, Hashable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    public init(speaker: String, start: Double, end: Double, text: String) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A stretch where one voice speaks, from the diarizer.
public struct SpeakerTurn: Equatable, Hashable, Sendable {
    public var speaker: String
    public var start: Double
    public var end: Double
    /// The voice's fingerprint on this stretch (empty when unknown).
    public var embedding: [Float]
    public init(speaker: String, start: Double, end: Double, embedding: [Float] = []) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

public struct MeetingApp: Codable, Equatable, Sendable {
    public var bundleID: String?
    public var name: String?
    public var windowTitle: String?
    public init(bundleID: String? = nil, name: String? = nil, windowTitle: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.windowTitle = windowTitle
    }
}

/// What happens to the recordings once the transcript is written.
public enum MeetingRetention: String, Codable, CaseIterable, Sendable {
    case delete, mixed7d = "mixed_7d", keepWAVs = "keep_wavs"
    public var label: String {
        switch self {
        case .delete: return "Delete the audio once the transcript is written"
        case .mixed7d: return "Keep a compact mixdown for 7 days"
        case .keepWAVs: return "Keep the raw recordings"
        }
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case recording, processing, ready, failed
}

/// A note the user typed while the call ran ("Mark" is an empty note).
public struct MeetingMark: Codable, Equatable, Sendable {
    public var at: Double
    public var text: String
    public init(at: Double, text: String = "") {
        self.at = at
        self.text = text
    }
}

/// `meta.json` of one meeting folder.
public struct MeetingMeta: Codable, Equatable, Sendable {
    public struct Audio: Codable, Equatable, Sendable {
        public var retention: MeetingRetention
        public var files: [String]
        public var deleteAfter: Date?
        public init(retention: MeetingRetention, files: [String] = [], deleteAfter: Date? = nil) {
            self.retention = retention
            self.files = files
            self.deleteAfter = deleteAfter
        }
    }
    public struct Processing: Codable, Equatable, Sendable {
        public var asr: String
        public var diarizer: String
        public var summaryModel: String?
        public var status: MeetingStatus
        public var error: String?
        public var echoRemoved: Int?
        public init(asr: String = "apple-speech", diarizer: String = "mochlet-lite", summaryModel: String? = nil, status: MeetingStatus = .recording, error: String? = nil, echoRemoved: Int? = nil) {
            self.asr = asr
            self.diarizer = diarizer
            self.summaryModel = summaryModel
            self.status = status
            self.error = error
            self.echoRemoved = echoRemoved
        }
    }

    public var id: String
    public var title: String
    public var titleEdited: Bool
    public var startedAt: Date
    public var endedAt: Date?
    public var durationS: Double
    public var app: MeetingApp
    public var locale: String
    public var speakers: [MeetingSpeaker]
    public var marks: [MeetingMark]
    public var audio: Audio
    public var processing: Processing
    public var kbPath: String?

    public init(id: String, title: String, startedAt: Date, app: MeetingApp = MeetingApp(), locale: String = "", retention: MeetingRetention = .mixed7d) {
        self.id = id
        self.title = title
        self.titleEdited = false
        self.startedAt = startedAt
        self.endedAt = nil
        self.durationS = 0
        self.app = app
        self.locale = locale
        self.speakers = []
        self.marks = []
        self.audio = Audio(retention: retention)
        self.processing = Processing()
        self.kbPath = nil
    }

    public func speaker(_ id: String) -> MeetingSpeaker? { speakers.first { $0.id == id } }
    public func name(of id: String) -> String { speaker(id)?.name ?? id }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What the brain writes about the call.
public struct MeetingSummary: Codable, Equatable, Sendable {
    public struct Decision: Codable, Equatable, Sendable {
        public var text: String
        public var context: String?
        public var ts: Double?
        public init(text: String, context: String? = nil, ts: Double? = nil) { self.text = text; self.context = context; self.ts = ts }
    }
    public struct ActionItem: Codable, Equatable, Sendable {
        public var text: String
        public var owner: String?
        public var due: String?
        public var ts: Double?
        public init(text: String, owner: String? = nil, due: String? = nil, ts: Double? = nil) { self.text = text; self.owner = owner; self.due = due; self.ts = ts }
    }
    public struct Topic: Codable, Equatable, Sendable {
        public var title: String
        public var start: Double?
        public var end: Double?
        public var summary: String
        public init(title: String, start: Double? = nil, end: Double? = nil, summary: String) { self.title = title; self.start = start; self.end = end; self.summary = summary }
    }
    public struct Participant: Codable, Equatable, Sendable {
        public var speakerID: String
        public var suggestedName: String?
        public var evidence: String?
        public init(speakerID: String, suggestedName: String? = nil, evidence: String? = nil) { self.speakerID = speakerID; self.suggestedName = suggestedName; self.evidence = evidence }
        enum CodingKeys: String, CodingKey { case speakerID = "speaker_id", suggestedName = "suggested_name", evidence }
    }

    public var title: String
    public var overview: String
    public var keywords: [String]
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]
    public var topics: [Topic]
    public var participants: [Participant]
    public var language: String?

    public init(title: String, overview: String, keywords: [String] = [], decisions: [Decision] = [], actionItems: [ActionItem] = [], openQuestions: [String] = [],
                topics: [Topic] = [], participants: [Participant] = [], language: String? = nil) {
        self.title = title
        self.overview = overview
        self.keywords = keywords
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.topics = topics
        self.participants = participants
        self.language = language
    }

    enum CodingKeys: String, CodingKey {
        case title, overview, keywords, decisions, topics, participants, language
        case actionItems = "action_items", openQuestions = "open_questions"
    }

    public var isEmpty: Bool { overview.isEmpty && decisions.isEmpty && actionItems.isEmpty && topics.isEmpty }
}

public enum MeetingTime {
    /// "00:12:34.560" (Lark's form) or "12:34" when short is asked.
    public static func stamp(_ seconds: Double, millis: Bool = true) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        let h = total / 3_600_000, m = total / 60_000 % 60, sec = total / 1000 % 60, ms = total % 1000
        return millis ? String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms) : String(format: "%02d:%02d:%02d", h, m, sec)
    }

    /// "35min 58s", "1h 05min 12s", "42s".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = s / 60 % 60, sec = s % 60
        if h > 0 { return String(format: "%dh %02dmin %02ds", h, m, sec) }
        if m > 0 { return "\(m)min \(String(format: "%02d", sec))s" }
        return "\(sec)s"
    }

    public static func parseStamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
