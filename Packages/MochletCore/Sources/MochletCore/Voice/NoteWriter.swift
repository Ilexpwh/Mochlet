import Foundation

/// Spoken or typed notes land in `notes/YYYY/MM/DD.md`, one `## HH:MM` entry each; the day page is a
/// `type: note` page the index and the linter see like any other.
public enum NoteWriter {
    public static func path(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%@/%04d/%02d/%02d.md", BundleLayout.notes, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// The day page with `text` appended under the current minute (a second note in the same minute joins it).
    public static func append(_ text: String, to existing: OKFDocument?, at date: Date, source: String = "voice", calendar: Calendar = .current) -> OKFDocument {
        let day = dayString(date, calendar: calendar)
        let time = timeString(date, calendar: calendar)
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fm = existing?.frontmatter ?? OKFFrontmatter(type: "note", title: "Notes \(day)", description: "Notes taken on \(day)")
        if fm.generated == nil { fm.generated = OKFStamp(by: BundleLayout.generator, at: date) }
        fm.status = fm.status ?? "stable"
        var kinds: [YAMLPair] = []
        if case .mapping(let pairs)? = fm.mochlet { kinds = pairs.filter { $0.key != "kind" && $0.key != "last_source" } }
        kinds.insert(YAMLPair("kind", .string("notes")), at: 0)
        kinds.append(YAMLPair("last_source", .string(source)))
        fm.mochlet = .mapping(kinds)
        var body = existing?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty { body = "# Notes \(day)" }
        let heading = "## \(time)"
        if body.hasSuffix(heading) || body.range(of: "(?s)\n\(heading)\n(?:(?!\n## ).)*$", options: .regularExpression)?.upperBound == body.endIndex {
            body += "\n\n" + entry
        } else {
            body += "\n\n" + heading + "\n\n" + entry
        }
        return OKFDocument(frontmatter: fm, body: body + "\n")
    }
}
