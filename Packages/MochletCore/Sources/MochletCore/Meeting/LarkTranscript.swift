import Foundation

/// The transcript file in the form Lark Minutes exports (so anything that reads those reads ours):
///
///     2026-11-04 11:03:33 CST|35min 58s
///
///     Keywords:
///     流量、语音、成本
///
///     Yifei Gao 00:00:20.680
///     text…
public enum LarkTranscript {
    public static func format(startedAt: Date, duration: Double, keywords: [String], lines: [MeetingLine], speakers: [MeetingSpeaker], timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let zone = Self.zoneName(timeZone, at: startedAt)
        var out = "\(f.string(from: startedAt)) \(zone)|\(MeetingTime.duration(duration))\n\n"
        out += "Keywords:\n" + (keywords.isEmpty ? "—" : keywords.joined(separator: "、")) + "\n\n"
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        for l in lines {
            out += "\(names[l.speaker] ?? l.speaker) \(MeetingTime.stamp(l.start))\n\(l.text)\n\n"
        }
        return out
    }

    /// Lark writes "CST" for China Standard Time where Foundation says "GMT+8".
    public static func zoneName(_ tz: TimeZone, at date: Date) -> String {
        switch tz.identifier {
        case "Asia/Shanghai", "Asia/Chongqing", "Asia/Harbin", "Asia/Urumqi", "Asia/Taipei", "PRC", "ROC": return "CST"
        case "Asia/Hong_Kong", "Hongkong": return "HKT"
        case "Asia/Macau", "Asia/Macao": return "CST"
        case "Asia/Singapore", "Singapore": return "SGT"
        case "Asia/Tokyo", "Japan": return "JST"
        case "Asia/Seoul", "ROK": return "KST"
        default:
            let a = tz.abbreviation(for: date) ?? tz.identifier
            return a
        }
    }

    public struct Parsed: Equatable, Sendable {
        public var header: String
        public var keywords: [String]
        public var lines: [MeetingLine]
        public var names: [String]
    }

    /// Reads a file in that form (ours or Lark's). Speaker ids are the names.
    public static func parse(_ text: String) -> Parsed {
        var header = ""
        var keywords: [String] = []
        var lines: [MeetingLine] = []
        var names: [String] = []
        var pendingName: String?
        var pendingStart: Double?
        var body: [String] = []
        let stamp = try! NSRegularExpression(pattern: #"^(.+?)\s+(\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?)\s*$"#)
        func flush() {
            guard let n = pendingName, let s = pendingStart else { return }
            let t = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                if !names.contains(n) { names.append(n) }
                lines.append(MeetingLine(speaker: n, start: s, end: s, text: t))
            }
            pendingName = nil; pendingStart = nil; body = []
        }
        var expectKeywords = false
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if i == 0 { header = line; continue }
            if expectKeywords { keywords = line == "—" ? [] : line.split(whereSeparator: { "、,，".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }; expectKeywords = false; continue }
            if line == "Keywords:" || line == "关键词：" || line == "关键词:" { expectKeywords = true; continue }
            if let m = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let nr = Range(m.range(at: 1), in: line), let sr = Range(m.range(at: 2), in: line),
               let s = MeetingTime.parseStamp(String(line[sr])) {
                flush()
                pendingName = String(line[nr]); pendingStart = s
                continue
            }
            if pendingName != nil { body.append(raw) }
        }
        flush()
        // End times: the next line's start (the last one keeps its start).
        for i in lines.indices where i + 1 < lines.count { lines[i].end = max(lines[i].start, lines[i + 1].start) }
        return Parsed(header: header, keywords: keywords, lines: lines, names: names)
    }
}
