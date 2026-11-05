import Foundation

/// What can be eaten.
public enum IngestInput: Sendable, Equatable {
    case file(URL)
    case url(URL)
    case text(String, title: String?)
    /// A captured window: title, app, URL when a browser, OCR/selected text.
    case window(title: String, app: String, url: String?, text: String)

    public var label: String {
        switch self {
        case .file(let u): return u.lastPathComponent
        case .url(let u): return u.host ?? u.absoluteString
        case .text(_, let t): return t ?? "text"
        case .window(let t, let app, _, _): return t.isEmpty ? app : t
        }
    }
}

/// One structural piece of an extracted document.
public enum ContentBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, text: String)
    case table(String)                       // Markdown table text
    case image(path: String?, description: String?)
    case slide(Int)                          // slide marker
    case page(Int)                           // page marker
    case turn(speaker: String?, start: Double, end: Double, text: String)
}

/// The extractor's output: Markdown plus the blocks it was assembled from.
public struct ExtractedContent: Sendable, Equatable {
    public var title: String
    public var markdown: String
    public var blocks: [ContentBlock]
    public var metadata: [String: String]
    public var language: String?
    public var warnings: [String]
    public var extractors: [String]
    /// Where the readable copy should be mirrored from (nil = the original file).
    public var mirrorText: String?
    public var mirrorExtension: String?
    public var resourceURL: String?

    public init(title: String, markdown: String, blocks: [ContentBlock] = [], metadata: [String: String] = [:], language: String? = nil,
                warnings: [String] = [], extractors: [String] = [], mirrorText: String? = nil, mirrorExtension: String? = nil, resourceURL: String? = nil) {
        self.title = title
        self.markdown = markdown
        self.blocks = blocks
        self.metadata = metadata
        self.language = language
        self.warnings = warnings
        self.extractors = extractors
        self.mirrorText = mirrorText
        self.mirrorExtension = mirrorExtension
        self.resourceURL = resourceURL
    }

    public var words: Int { markdown.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }
    public var isEmpty: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Markdown from blocks, when an extractor builds blocks first.
    public static func render(_ blocks: [ContentBlock]) -> String {
        var out: [String] = []
        for b in blocks {
            switch b {
            case .heading(let l, let t): out.append(String(repeating: "#", count: max(1, min(6, l))) + " " + t)
            case .paragraph(let t): out.append(t)
            case .code(let lang, let t): out.append("```\(lang ?? "")\n\(t)\n```")
            case .table(let t): out.append(t)
            case .image(let p, let d): out.append("![\(d ?? "image")](\(p ?? ""))")
            case .slide(let n): out.append("<!-- slide: \(n) -->")
            case .page(let n): out.append("<!-- page: \(n) -->")
            case .turn(let s, let start, _, let t): out.append("\(s.map { "**\($0)** " } ?? "")(\(TranscriptTime.format(start))) \(t)")
            }
        }
        return out.joined(separator: "\n\n") + "\n"
    }
}

public enum TranscriptTime {
    public static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Where an ingest is.
public enum IngestStage: String, Sendable, Codable, CaseIterable {
    case reading, extracting, ocr, transcribing, analysing, routing, filing, indexing, integrating, done, failed

    public var label: String {
        switch self {
        case .reading: return "reading"
        case .extracting: return "extracting text"
        case .ocr: return "recognising text"
        case .transcribing: return "transcribing"
        case .analysing: return "analysing"
        case .routing: return "choosing a project"
        case .filing: return "filing"
        case .indexing: return "indexing"
        case .integrating: return "integrating"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// Rough share of the whole job that is finished when this stage begins.
    public var progressStart: Double {
        switch self {
        case .reading: return 0.02
        case .extracting: return 0.1
        case .ocr: return 0.2
        case .transcribing: return 0.2
        case .analysing: return 0.45
        case .routing: return 0.75
        case .filing: return 0.82
        case .indexing: return 0.88
        case .integrating: return 0.92
        case .done, .failed: return 1
        }
    }
}

/// A project question the router could not settle on its own.
public struct ProjectQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public var slug: String?        // nil = inbox
        public var name: String
        public var confidence: Double
        public var id: String { slug ?? "inbox" }
        public init(slug: String?, name: String, confidence: Double) {
            self.slug = slug
            self.name = name
            self.confidence = confidence
        }
    }
    public var options: [Option]
    public var suggested: String?       // slug of the default (auto-accepted after the timeout)
    public init(options: [Option], suggested: String?) {
        self.options = options
        self.suggested = suggested
    }
}

/// Keys for `project_priors`: who sent it, what it is, where it came from.
public enum PriorKeys {
    public static func keys(host: String?, tags: [String], sourceDirectory: String?) -> [String] {
        var out: [String] = []
        if let h = host, !h.isEmpty { out.append("host:" + h.lowercased()) }
        for t in tags.prefix(6) { out.append("tag:" + t.lowercased()) }
        if let d = sourceDirectory, !d.isEmpty { out.append("dir:" + d) }
        return out
    }
}

/// "zh" when CJK characters make up a real share of the letters, else "en" (a stray Chinese phrase in an
/// English document does not make it Chinese).
public enum LanguageGuess {
    public static func code(_ text: String, sample: Int = 2000) -> String {
        var cjk = 0
        var letters = 0
        for u in text.unicodeScalars.prefix(sample) {
            if CJK.isCJK(u) { cjk += 1; letters += 1 }
            else if u.properties.isAlphabetic { letters += 1 }
        }
        guard letters > 0 else { return "en" }
        return Double(cjk) / Double(letters) >= 0.15 ? "zh" : "en"
    }
}
