import Foundation

/// What the brain is asked for a meeting: notes per 15-minute window when the call is long, then one
/// summary with decisions, action items, open questions, topics and who the speakers seem to be.
public enum MeetingPrompts {
    public static let summarySystem = """
    You write the notes of a meeting from its transcript. The transcript lines are "[HH:MM:SS] Speaker: words"; \
    speakers are "Me" (the person whose Mac recorded) and "Person 2", "Person 3"… until named. \
    Fill the schema. Keep the language of the meeting (do not translate; mixed stays mixed); keep names, \
    numbers, product names and dates as said. Never invent a name: suggest a real name for a speaker only when \
    the transcript makes it certain (they say their own name, or are addressed by it), with the evidence. \
    Decisions are things agreed, not things discussed; action items name the owner when the transcript does. \
    Timestamps (ts, start, end) are seconds from the start of the meeting, taken from the line stamps. \
    The overview is two to four sentences a colleague who missed the call can read first. Keywords: 5 to 12 \
    short terms. Topics: 2 to 8, in order, each with a one- or two-sentence summary.
    """

    public static let windowSystem = """
    You take notes on one part of a long meeting transcript (lines "[HH:MM:SS] Speaker: words"). Write what was \
    said, decided and asked, who said it, with the timestamps, in the language of the meeting. Invent nothing.
    """

    public static var summarySchema: JSONValue {
        Schemas.object([
            "title": Schemas.string("A short title for the meeting (what it was about), in its language."),
            "overview": Schemas.string("Two to four sentences."),
            "keywords": Schemas.strings("5–12 short terms."),
            "decisions": Schemas.array(Schemas.object(["text": Schemas.string("The decision."), "context": Schemas.string("Why, briefly."), "ts": Schemas.number("Seconds from the start.")], required: ["text"]), "Things agreed."),
            "action_items": Schemas.array(Schemas.object(["text": Schemas.string("The task."), "owner": Schemas.string("Who, as named in the transcript."), "due": Schemas.string("When, as said."), "ts": Schemas.number("Seconds from the start.")], required: ["text"]), "Tasks taken."),
            "open_questions": Schemas.strings("Questions left open."),
            "topics": Schemas.array(Schemas.object(["title": Schemas.string("Topic."), "start": Schemas.number("Seconds."), "end": Schemas.number("Seconds."), "summary": Schemas.string("One or two sentences.")], required: ["title", "summary"]), "Topics in order."),
            "participants": Schemas.array(Schemas.object(["speaker_id": Schemas.string("me, p2, p3…"), "suggested_name": Schemas.string("Only when certain."), "evidence": Schemas.string("The line that names them.")], required: ["speaker_id"]), "One per speaker id."),
            "language": Schemas.string("BCP-47 of the meeting: zh-Hans, en, mixed…"),
        ], required: ["title", "overview", "keywords", "decisions", "action_items", "open_questions", "topics", "participants"])
    }

    public static var windowSchema: JSONValue {
        Schemas.object(["notes": Schemas.string("The notes of this part, with timestamps.")], required: ["notes"])
    }

    /// "[00:12:34] Alice: text" per line.
    public static func render(_ lines: [MeetingLine], speakers: [MeetingSpeaker]) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        return lines.map { "[\(MeetingTime.stamp($0.start, millis: false))] \(names[$0.speaker] ?? $0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    public static func user(transcript: String, title: String?, app: String?, started: Date, duration: Double, marks: [MeetingMark]) -> String {
        var s = "Meeting"
        if let title, !title.isEmpty { s += " \"\(title)\"" }
        if let app, !app.isEmpty { s += " in \(app)" }
        s += ", \(started.formatted(date: .abbreviated, time: .shortened)), \(MeetingTime.duration(duration)).\n"
        if !marks.isEmpty {
            s += "Marks the user set during the call: " + marks.map { "[\(MeetingTime.stamp($0.at, millis: false))]" + ($0.text.isEmpty ? "" : " \($0.text)") }.joined(separator: "; ") + "\n"
        }
        s += "\n<transcript>\n\(transcript)\n</transcript>"
        return s
    }

    public static func windowUser(_ text: String, index: Int, count: Int) -> String {
        "Part \(index + 1) of \(count).\n\n<transcript>\n\(text)\n</transcript>"
    }

    public static func reduceUser(notes: [String], title: String?, app: String?, started: Date, duration: Double, marks: [MeetingMark]) -> String {
        var s = user(transcript: "", title: title, app: app, started: started, duration: duration, marks: marks)
        s = s.replacingOccurrences(of: "\n<transcript>\n\n</transcript>", with: "")
        s += "\nThe meeting was long; these are the notes of its parts, in order. Write the summary from them.\n\n"
        for (i, n) in notes.enumerated() { s += "<part index=\"\(i + 1)\">\n\(n)\n</part>\n" }
        return s
    }

    /// Above this many characters the transcript is summarised in windows first.
    public static let directLimit = 60_000
}
