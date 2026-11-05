import Foundation

/// The files of a finished meeting: `summary.md`, and the knowledge page (`type: meeting`) that links
/// the transcript and carries it in full so the knowledge base can answer "what did we decide about…".
public enum MeetingWriter {
    public static func slug(title: String, startedAt: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let base = Slug.make(title)
        return f.string(from: startedAt) + "-" + (base.isEmpty || base.hasPrefix("untitled") ? "meeting" : String(base.prefix(40)))
    }

    public static func defaultTitle(app: MeetingApp, startedAt: Date) -> String {
        if let t = app.windowTitle, !t.isEmpty, t.count <= 60, MeetingDetectionRules.titleMatch(t) == nil { return t }
        let name = app.name ?? "Meeting"
        return "\(name) \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The meeting's title: the one the person typed, else the summary's, else the default.
    public static func title(_ meta: MeetingMeta, summary: MeetingSummary?) -> String {
        if meta.titleEdited { return meta.title }
        if let t = summary?.title.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        return meta.title
    }

    public static func summaryMarkdown(_ s: MeetingSummary, meta: MeetingMeta) -> String {
        var out = "# \(title(meta, summary: s))\n\n"
        out += "_\(meta.startedAt.formatted(date: .complete, time: .shortened)) · \(MeetingTime.duration(meta.durationS))"
        if let a = meta.app.name, !a.isEmpty { out += " · \(a)" }
        out += "_  \n_" + meta.speakers.map(\.name).joined(separator: ", ") + "_\n\n"
        if !s.overview.isEmpty { out += "## Overview\n\n\(s.overview)\n\n" }
        if !s.keywords.isEmpty { out += "**Keywords:** " + s.keywords.joined(separator: " · ") + "\n\n" }
        if !s.decisions.isEmpty {
            out += "## Decisions\n\n" + s.decisions.map { d in "- " + stampLink(d.ts) + d.text + (d.context.map { " — \($0)" } ?? "") }.joined(separator: "\n") + "\n\n"
        }
        if !s.actionItems.isEmpty {
            out += "## Action items\n\n" + s.actionItems.map { a in
                "- [ ] " + stampLink(a.ts) + a.text + (a.owner.map { " — **\($0)**" } ?? "") + (a.due.map { " (\($0))" } ?? "")
            }.joined(separator: "\n") + "\n\n"
        }
        if !s.openQuestions.isEmpty { out += "## Open questions\n\n" + s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        if !s.topics.isEmpty {
            out += "## Topics\n\n" + s.topics.map { t in "### " + stampLink(t.start) + t.title + "\n\n" + t.summary }.joined(separator: "\n\n") + "\n\n"
        }
        if !meta.marks.isEmpty {
            out += "## Marks\n\n" + meta.marks.map { "- \(MeetingTime.stamp($0.at, millis: false))" + ($0.text.isEmpty ? "" : " \($0.text)") }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    static func stampLink(_ ts: Double?) -> String {
        guard let ts else { return "" }
        return "`\(MeetingTime.stamp(ts, millis: false))` "
    }

    /// The knowledge page: summary on top, the full transcript below, timestamps kept.
    public static func knowledgePage(meta: MeetingMeta, summary: MeetingSummary?, lines: [MeetingLine], transcriptURL: URL, folderURL: URL, now: Date = Date()) -> OKFDocument {
        let title = title(meta, summary: summary)
        var fm = OKFFrontmatter(type: "meeting", title: title, description: OneLine.collapse(summary?.overview ?? "Meeting transcript", limit: 200))
        fm.resource = transcriptURL.absoluteString
        fm.tags = Array((summary?.keywords ?? []).prefix(8))
        fm.status = "stable"
        fm.generated = OKFStamp(by: BundleLayout.generator, at: now)
        fm.sources = [OKFSource(id: "transcript", resource: transcriptURL.absoluteString, title: "Transcript", lastModified: OKFDate.format(now))]
        var m: [YAMLPair] = [YAMLPair("kind", .string("meeting")), YAMLPair("dir", .string(folderURL.path)), YAMLPair("started_at", .string(OKFDate.format(meta.startedAt))),
                             YAMLPair("duration_s", .int(Int(meta.durationS.rounded())))]
        if let b = meta.app.bundleID { m.append(YAMLPair("app", .string(b))) }
        if let n = meta.app.name { m.append(YAMLPair("app_name", .string(n))) }
        m.append(YAMLPair("speakers", .sequence(meta.speakers.map { .string($0.name) })))
        if let l = summary?.language { m.append(YAMLPair("language", .string(l))) }
        fm.mochlet = .mapping(m)
        var body = "# \(title)\n\n"
        if let summary {
            let md = summaryMarkdown(summary, meta: meta)
            if let r = md.range(of: "\n\n") { body += String(md[r.upperBound...]) }
        } else {
            body += "_\(meta.startedAt.formatted(date: .complete, time: .shortened)) · \(MeetingTime.duration(meta.durationS))_\n\n"
        }
        body += "## Transcript\n\n[transcript.md](\(transcriptURL.absoluteString)) · [folder](\(folderURL.absoluteString))\n\n"
        let names = Dictionary(uniqueKeysWithValues: meta.speakers.map { ($0.id, $0.name) })
        for l in lines {
            body += "**\(names[l.speaker] ?? l.speaker)** `\(MeetingTime.stamp(l.start, millis: false))`  \n\(l.text)\n\n"
        }
        return OKFDocument(frontmatter: fm, body: body)
    }
}
