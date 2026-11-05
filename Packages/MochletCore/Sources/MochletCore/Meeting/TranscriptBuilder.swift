import Foundation

/// The transcript of a call from the two recordings: the microphone is you, the Mac's sound is the
/// others, told apart by the diarizer. Pure (tests in MeetingTests).
public enum TranscriptBuilder {
    /// Phrases further apart than this start a new line.
    public static let pause = 1.4
    /// A line never gets longer than this, so the transcript stays readable.
    public static let maxLineSeconds = 40.0
    public static let meID = "me"
    public static let fragmentLongest = 3.0

    public static func personName(_ number: Int) -> String { "Person \(number)" }

    /// The others' phrases, each given to the voice speaking at that moment (or the nearest one).
    public static func assign(_ phrases: [TimedPhrase], to turns: [SpeakerTurn], fallback: String) -> [(speaker: String, phrase: TimedPhrase)] {
        phrases.map { p in
            let mid = (p.start + p.end) / 2
            if let best = turns.filter({ $0.start < p.end && p.start < $0.end }).max(by: { overlap($0, p) < overlap($1, p) }) {
                return (best.speaker, p)
            }
            if let turn = turns.first(where: { mid >= $0.start && mid <= $0.end }) { return (turn.speaker, p) }
            let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
            if let nearest, distance(mid, nearest) < 2 { return (nearest.speaker, p) }
            return (fallback, p)
        }
    }

    private static func overlap(_ t: SpeakerTurn, _ p: TimedPhrase) -> Double { max(0, min(t.end, p.end) - max(t.start, p.start)) }
    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double { t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0) }

    /// Consecutive phrases of the same speaker, close in time, make one line.
    public static func lines(from phrases: [(speaker: String, phrase: TimedPhrase)]) -> [MeetingLine] {
        var out: [MeetingLine] = []
        for (speaker, p) in phrases {
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.speaker == speaker, p.start - last.end < pause, p.end - last.start < maxLineSeconds {
                last.text += join(last.text, text)
                last.end = max(last.end, p.end)
                out[out.count - 1] = last
            } else {
                out.append(MeetingLine(speaker: speaker, start: p.start, end: p.end, text: text))
            }
        }
        return out
    }

    /// What goes between two phrases: nothing at a CJK seam, a space otherwise.
    static func join(_ a: String, _ b: String) -> String {
        let seam = (a.last.map(EchoRemoval.isCJK) ?? false) || (b.first.map(EchoRemoval.isCJK) ?? false)
        return (seam ? "" : " ") + b
    }

    /// A voice heard only in short bits ("Yeah.", "Sure.") is almost always someone already there: such
    /// bits go to the closest real voice (by fingerprint, else the nearest in time). A voice is real once
    /// it speaks 3 s in a row, or long enough overall.
    public static func mergingFragments(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var total: [String: Double] = [:], longest: [String: Double] = [:]
        for t in turns {
            let length = t.end - t.start
            total[t.speaker, default: 0] += length
            longest[t.speaker] = max(longest[t.speaker] ?? 0, length)
        }
        guard total.count > 1 else { return turns }
        let all = total.values.reduce(0, +)
        let solid = Set(total.keys.filter { (longest[$0] ?? 0) >= fragmentLongest || (total[$0] ?? 0) >= max(20, all * 0.1) })
        guard !solid.isEmpty, solid.count < total.count else { return turns }
        var centroids: [String: [Float]] = [:]
        for speaker in solid {
            var sum: [Float] = []
            for t in turns where t.speaker == speaker && !t.embedding.isEmpty {
                let unit = normalized(t.embedding)
                let weight = Float(t.end - t.start)
                if sum.isEmpty { sum = [Float](repeating: 0, count: unit.count) }
                guard unit.count == sum.count else { continue }
                for k in sum.indices { sum[k] += unit[k] * weight }
            }
            if !sum.isEmpty { centroids[speaker] = normalized(sum) }
        }
        let solidTurns = turns.filter { solid.contains($0.speaker) }
        return turns.map { t in
            guard !solid.contains(t.speaker) else { return t }
            var t = t
            if !t.embedding.isEmpty, centroids.count == solid.count {
                let unit = normalized(t.embedding)
                if let best = centroids.max(by: { dot(unit, $0.value) < dot(unit, $1.value) }) { t.speaker = best.key; return t }
            }
            let mid = (t.start + t.end) / 2
            if let nearest = solidTurns.min(by: { distance(mid, $0) < distance(mid, $1) }) { t.speaker = nearest.speaker }
            return t
        }
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }

    /// The whole transcript: your lines (echo removed) and the others', in time order, speakers named in
    /// the order they first speak.
    public static func build(mine: [TimedPhrase], others: [TimedPhrase], turns: [SpeakerTurn], meName: String = "Me") -> (speakers: [MeetingSpeaker], lines: [MeetingLine]) {
        let myLines = lines(from: mine.map { (meID, $0) })
        let theirLines = lines(from: assign(others, to: turns, fallback: "others"))
        let all = (myLines + theirLines).sorted { $0.start < $1.start }
        var speakers: [MeetingSpeaker] = []
        if !myLines.isEmpty || others.isEmpty { speakers.append(MeetingSpeaker(id: meID, name: meName, isMe: true)) }
        var ids: [String: String] = [:]
        var renamed: [MeetingLine] = []
        for var line in all {
            if line.speaker != meID {
                if let id = ids[line.speaker] {
                    line.speaker = id
                } else {
                    let number = speakers.filter { !$0.isMe }.count + 2
                    let id = "p\(number)"
                    ids[line.speaker] = id
                    speakers.append(MeetingSpeaker(id: id, name: personName(number)))
                    line.speaker = id
                }
            }
            renamed.append(line)
        }
        return (speakers, renamed)
    }

    /// One recording for everyone (people around the Mac): the diarizer tells the voices apart.
    public static func buildRoom(phrases: [TimedPhrase], turns: [SpeakerTurn]) -> (speakers: [MeetingSpeaker], lines: [MeetingLine]) {
        let raw = lines(from: assign(phrases, to: turns, fallback: "others"))
        var speakers: [MeetingSpeaker] = []
        var ids: [String: String] = [:]
        let named = raw.map { line -> MeetingLine in
            var line = line
            if let id = ids[line.speaker] { line.speaker = id } else {
                let number = speakers.count + 1
                let id = "p\(number)"
                ids[line.speaker] = id
                speakers.append(MeetingSpeaker(id: id, name: personName(number)))
                line.speaker = id
            }
            return line
        }
        return (speakers, named)
    }

    /// Renaming p3 to "Alice" or merging p4 into p2: the lines follow.
    public static func rename(_ lines: [MeetingLine], speakers: [MeetingSpeaker], id: String, to name: String) -> [MeetingSpeaker] {
        speakers.map { var s = $0; if s.id == id { s.name = name }; return s }
    }
    public static func merge(_ lines: [MeetingLine], speakers: [MeetingSpeaker], id: String, into target: String) -> ([MeetingSpeaker], [MeetingLine]) {
        guard id != target else { return (speakers, lines) }
        let moved = lines.map { l -> MeetingLine in var l = l; if l.speaker == id { l.speaker = target }; return l }
        var out: [MeetingLine] = []
        for l in moved {
            if var last = out.last, last.speaker == l.speaker, l.start - last.end < pause, l.end - last.start < maxLineSeconds {
                last.text += join(last.text, l.text)
                last.end = max(last.end, l.end)
                out[out.count - 1] = last
            } else { out.append(l) }
        }
        return (speakers.filter { $0.id != id }, out)
    }

    /// Lines split into windows of `seconds` (for the summary's map step).
    public static func windows(_ lines: [MeetingLine], seconds: Double = 900) -> [[MeetingLine]] {
        var out: [[MeetingLine]] = []
        var current: [MeetingLine] = []
        var windowStart = lines.first?.start ?? 0
        for l in lines {
            if l.start - windowStart >= seconds, !current.isEmpty {
                out.append(current)
                current = []
                windowStart = l.start
            }
            current.append(l)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
