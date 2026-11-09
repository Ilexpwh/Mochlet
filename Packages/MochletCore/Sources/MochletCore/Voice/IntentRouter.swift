import Foundation

/// What a spoken (or typed) utterance asks Mochlet to do.
public enum VoiceIntent: String, CaseIterable, Sendable, Codable {
    case ask
    case kbQuery = "kb_query"
    case projectStart = "project_start"
    case projectCreate = "project_create"
    case ingestURL = "ingest_url"
    case note
    case settingsOpen = "settings_open"
    case meetingStart = "meeting_start"
    case meetingStop = "meeting_stop"
    case signalsShow = "signals_show"
    case dictate
    case cancel

    /// Criteria for the decision engine.
    public var criteria: String {
        switch self {
        case .ask: return "A question or request for the assistant to answer or do in chat (general knowledge, summarise what an agent is doing, explain something)."
        case .kbQuery: return "A question about the user's own saved material: notes, files, meetings, links they filed earlier."
        case .projectStart: return "Start or continue work in a named project with a coding agent: 'work on X: …', 'let X do …', 'resume X'."
        case .projectCreate: return "Register, create or clone a project folder: 'add project …', 'make … a project', 'clone …'."
        case .ingestURL: return "Save, read or chew a link, the clipboard link, a page or file into the knowledge base."
        case .note: return "Write something down for later: a note, a reminder, a thought ('note to self …', 'remember that …')."
        case .settingsOpen: return "Open the settings or preferences."
        case .meetingStart: return "Start taking meeting notes or recording the current call."
        case .meetingStop: return "Stop the meeting notes or recording."
        case .signalsShow: return "Show today's AI news, hot topics or signals digest."
        case .dictate: return "Dictation: the words themselves are the text to type into the open input, not a command."
        case .cancel: return "Never mind, cancel, nothing."
        }
    }
}

/// A routed utterance with its slots filled as far as the text allows.
public struct RoutedIntent: Equatable, Sendable {
    public var intent: VoiceIntent
    public var text: String
    public var project: Project?
    public var projectName: String?
    public var task: String?
    public var url: URL?
    public var path: String?
    public var name: String?
    public var confidence: Double
    public var backend: String

    public init(intent: VoiceIntent, text: String, project: Project? = nil, projectName: String? = nil, task: String? = nil, url: URL? = nil,
                path: String? = nil, name: String? = nil, confidence: Double = 1, backend: String = "rule") {
        self.intent = intent
        self.text = text
        self.project = project
        self.projectName = projectName
        self.task = task
        self.url = url
        self.path = path
        self.name = name
        self.confidence = confidence
        self.backend = backend
    }

    /// A project_start without a resolvable project needs one more answer.
    public var missingProject: Bool { intent == .projectStart && project == nil }
}

/// Deterministic pre-pass, decision request and slot filling for voice input. Pure: the app brings the
/// clipboard, the projects and whether a text field is focused.
public enum IntentRouter {
    public struct Context: Sendable {
        public var clipboardURL: URL?
        public var chatFocused: Bool
        public var projects: [Project]
        public init(clipboardURL: URL? = nil, chatFocused: Bool = false, projects: [Project] = []) {
            self.clipboardURL = clipboardURL
            self.chatFocused = chatFocused
            self.projects = projects
        }
    }

    /// Rules first: URLs, clipboard links, notes, project commands, cancel words, settings, meetings, signals.
    public static func prepass(_ raw: String, context: Context) -> RoutedIntent? {
        let text = clean(raw)
        guard !text.isEmpty else { return RoutedIntent(intent: .cancel, text: "") }
        let lower = text.lowercased()
        if isCancel(lower) { return RoutedIntent(intent: .cancel, text: text) }
        if let url = firstURL(in: text) { return RoutedIntent(intent: .ingestURL, text: text, url: url) }
        if let u = context.clipboardURL, mentionsClipboardLink(lower) { return RoutedIntent(intent: .ingestURL, text: text, url: u) }
        if let body = noteBody(text) { return RoutedIntent(intent: .note, text: text, task: body) }
        // App commands before project commands: "open settings" is not "open <project>".
        if matches(lower, settingsWords) { return RoutedIntent(intent: .settingsOpen, text: text) }
        if matches(lower, meetingStopWords) { return RoutedIntent(intent: .meetingStop, text: text) }
        if matches(lower, meetingStartWords) { return RoutedIntent(intent: .meetingStart, text: text) }
        if matches(lower, signalsWords) { return RoutedIntent(intent: .signalsShow, text: text) }
        if let p = ProjectIntentParser.parse(text) { return fromProjectIntent(p, text: text, context: context) }
        if matches(lower, knowledgeWords) { return RoutedIntent(intent: .kbQuery, text: stripKnowledgePrefix(text)) }
        if context.chatFocused { return RoutedIntent(intent: .dictate, text: text) }
        return nil
    }

    /// The typed-choice question for everything the rules did not catch.
    public static func request(_ raw: String, context: Context) -> DecisionRequest {
        let text = clean(raw)
        var state = "Utterance: \(text)\n"
        state += "Registered projects: " + (context.projects.isEmpty ? "none" : context.projects.map(\.name).joined(separator: ", ")) + "\n"
        state += "A chat input is focused: \(context.chatFocused ? "yes" : "no")\n"
        state += "The clipboard holds a link: \(context.clipboardURL == nil ? "no" : "yes")"
        let options = VoiceIntent.allCases.map { DecisionOption(id: $0.rawValue, description: $0.criteria) }
        return DecisionRequest(state: state,
                               instructions: "Which kind of request is this utterance? Pick the single best option.",
                               options: options, tag: "intent")
    }

    /// Slots for the intent the engine chose.
    public static func fill(_ answer: DecisionAnswer, text raw: String, context: Context) -> RoutedIntent {
        let text = clean(raw)
        let intent = VoiceIntent(rawValue: answer.choice) ?? .ask
        var r = fill(intent, text: text, context: context)
        r.confidence = answer.confidence
        r.backend = answer.backend
        return r
    }

    public static func fill(_ intent: VoiceIntent, text: String, context: Context) -> RoutedIntent {
        switch intent {
        case .projectStart:
            let (project, name, task) = projectAndTask(text, context: context)
            return RoutedIntent(intent: .projectStart, text: text, project: project, projectName: name, task: task)
        case .projectCreate:
            return RoutedIntent(intent: .projectCreate, text: text, name: projectName(in: text, context: context).1)
        case .ingestURL:
            return RoutedIntent(intent: .ingestURL, text: text, url: firstURL(in: text) ?? context.clipboardURL)
        case .note:
            return RoutedIntent(intent: .note, text: text, task: noteBody(text) ?? text)
        case .kbQuery:
            return RoutedIntent(intent: .kbQuery, text: stripKnowledgePrefix(text))
        default:
            return RoutedIntent(intent: intent, text: text)
        }
    }

    // MARK: Rules

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?,".contains(last) { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static let cancelWords = ["cancel", "never mind", "nevermind", "forget it", "nothing", "no", "stop"]
    public static func isCancel(_ lower: String) -> Bool {
        let t = lower.trimmingCharacters(in: .whitespaces)
        return cancelWords.contains(t) || (t.count <= 12 && cancelWords.contains { t.hasPrefix($0) && t.count - $0.count <= 3 })
    }

    static let clipboardWords = ["this link", "that link", "the link", "clipboard", "copied link", "the url"]
    static func mentionsClipboardLink(_ lower: String) -> Bool { clipboardWords.contains { lower.contains($0) } }

    static let noteTriggers = ["take a note", "make a note", "note to self", "note that", "note:", "note down", "remember that", "remind me that", "jot down", "write down"]
    static func noteBody(_ text: String) -> String? {
        let lower = text.lowercased()
        for t in noteTriggers {
            guard let r = lower.range(of: t) else { continue }
            let before = lower[lower.startIndex..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            guard before.isEmpty || before.count <= 8 else { continue }      // "ok so remember that …" is fine; a trigger deep in a sentence is not
            var body = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            for sep in [":", ",", "-", "—"] where body.hasPrefix(sep) { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return body.isEmpty ? nil : body
        }
        return nil
    }

    static let settingsWords = ["open settings", "open preferences", "show settings", "settings", "preferences"]
    static let meetingStartWords = ["start taking notes", "start taking meeting notes", "taking meeting notes", "start meeting notes", "take meeting notes", "meeting notes",
                                    "start recording", "record this meeting", "record the meeting", "note taker", "start the notes"]
    static let meetingStopWords = ["stop taking notes", "stop taking meeting notes", "stop meeting notes", "stop recording", "stop the recording", "end the meeting notes",
                                   "end meeting notes", "stop notes", "stop the notes", "finish the meeting notes"]
    static let signalsWords = ["signals", "what's hot", "whats hot", "what is hot", "ai news", "today's ai", "todays ai", "show the digest", "the digest"]
    static let knowledgeWords = ["kb:", "knowledge base", "my notes", "my knowledge", "in my notes", "did i save", "what did i save", "search my", "look up in my"]
    static func matches(_ lower: String, _ words: [String]) -> Bool {
        let t = lower.trimmingCharacters(in: .whitespaces)
        return words.contains { w in
            if t == w { return true }
            guard t.contains(w) else { return false }
            // Short triggers ("settings") only count when the utterance is about them.
            return w.count >= 6 || t.count <= w.count + 12
        }
    }

    static func stripKnowledgePrefix(_ text: String) -> String {
        var t = text
        for p in ["kb:", "ask the knowledge base", "in my notes,", "in my notes"] {
            if t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        }
        return t.isEmpty ? text : t
    }

    public static func firstURL(in text: String) -> URL? {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        for m in d.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let u = m.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            return u
        }
        if let r = text.range(of: #"(?i)\b(?:https?://|www\.)\S+"#, options: .regularExpression) {
            var s = String(text[r])
            if s.lowercased().hasPrefix("www.") { s = "https://" + s }
            return URL(string: s)
        }
        return nil
    }

    static func fromProjectIntent(_ p: ProjectIntent, text: String, context: Context) -> RoutedIntent {
        switch p {
        case .workOn(let name, let task, _):
            return RoutedIntent(intent: .projectStart, text: text, project: ProjectMatcher.match(name, in: context.projects), projectName: name, task: task)
        case .resume(let name, _):
            return RoutedIntent(intent: .projectStart, text: text, project: ProjectMatcher.match(name, in: context.projects), projectName: name, task: "")
        case .open(let name, _):
            return RoutedIntent(intent: .projectStart, text: text, project: ProjectMatcher.match(name, in: context.projects), projectName: name, task: "")
        case .makeProject(let path, let name):
            return RoutedIntent(intent: .projectCreate, text: text, path: path, name: name)
        case .clone(let url, let name):
            return RoutedIntent(intent: .projectCreate, text: text, url: URL(string: url), name: name)
        case .listProjects:
            return RoutedIntent(intent: .projectCreate, text: text)
        }
    }

    /// The project named somewhere in the text (longest name wins), with the remainder as the task.
    static func projectAndTask(_ text: String, context: Context) -> (Project?, String?, String?) {
        guard let (project, name) = bestProject(in: text, context: context) else { return (nil, nil, text) }
        var task = text
        if let r = task.range(of: name, options: [.caseInsensitive]) { task.removeSubrange(r) }
        for w in ["work on", "working on", "continue", "resume", "let", "have", "ask", "tell", "in the project", "the project", "project", "on", "in", "with", "for", ":"] {
            let lower = task.lowercased()
            if lower.hasPrefix(w + " ") || lower.hasPrefix(w) && w.unicodeScalars.first.map({ !CharacterSet.letters.contains($0) }) == true {
                task = String(task.dropFirst(w.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (project, name, task.trimmingCharacters(in: CharacterSet(charactersIn: " :,")))
    }

    public static func bestProject(in text: String, context: Context) -> (Project, String)? {
        let lower = text.lowercased()
        var best: (Project, String)?
        for p in context.projects where !p.archived {
            for n in [p.name, p.slug] + p.aliases where !n.isEmpty {
                guard lower.contains(n.lowercased()) else { continue }
                if best == nil || n.count > best!.1.count { best = (p, n) }
            }
        }
        if best == nil {
            // "work on mochlit" — a fuzzy single word after a trigger.
            for w in text.split(whereSeparator: { $0 == " " || $0 == ":" }) {
                let q = String(w).trimmingCharacters(in: .punctuationCharacters)
                if q.count >= 3, let p = ProjectMatcher.match(q, in: context.projects) { return (p, q) }
            }
        }
        return best
    }

    static func projectName(in text: String, context: Context) -> (Project?, String?) {
        if let (p, n) = bestProject(in: text, context: context) { return (p, n) }
        for p in [#"(?i)(?:called|named)\s+(\S+)"#] {
            if let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text) {
                return (nil, String(text[r]).trimmingCharacters(in: .punctuationCharacters))
            }
        }
        return (nil, nil)
    }
}
