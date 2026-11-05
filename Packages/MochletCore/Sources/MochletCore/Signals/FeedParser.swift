import Foundation

/// One entry of an RSS 2.0, Atom or RDF feed.
public struct FeedEntry: Sendable, Equatable {
    public var id: String
    public var title: String
    public var link: String
    public var summary: String
    public var content: String
    public var author: String?
    public var published: Date?
    public init(id: String, title: String, link: String, summary: String = "", content: String = "", author: String? = nil, published: Date? = nil) {
        self.id = id
        self.title = title
        self.link = link
        self.summary = summary
        self.content = content
        self.author = author
        self.published = published
    }
}

public struct Feed: Sendable, Equatable {
    public var title: String
    public var link: String
    public var entries: [FeedEntry]
    public init(title: String = "", link: String = "", entries: [FeedEntry] = []) {
        self.title = title
        self.link = link
        self.entries = entries
    }
}

/// Hand-rolled feed parser on Foundation's XMLParser: RSS 2.0 (`<item>`), Atom (`<entry>`) and RDF 1.0
/// (`<item rdf:about>`), with `content:encoded`, `dc:date`, `dc:creator`, CDATA and HTML in summaries.
public enum FeedParser {
    public static func parse(_ data: Data) -> Feed? {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        p.shouldProcessNamespaces = false
        guard p.parse() || !d.entries.isEmpty else { return nil }
        guard d.sawFeed else { return nil }
        return Feed(title: d.feedTitle.trimmed, link: d.feedLink.trimmed, entries: d.entries)
    }

    public static func parse(_ text: String) -> Feed? { parse(Data(text.utf8)) }

    /// Dates as feeds write them: RFC 822 in its variants, ISO 8601 with or without fractions, plain days.
    public static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }

    private static let formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm", "yyyy/MM/dd", "MMM dd, yyyy", "MMMM dd, yyyy", "dd MMM yyyy",
    ].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = fmt
        return f
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawFeed = false
        var feedTitle = ""
        var feedLink = ""
        var entries: [FeedEntry] = []
        private var stack: [String] = []
        private var inEntry = false
        private var text = ""
        private var cur: [String: String] = [:]
        private var atomLinkAlternate: String?
        private var atomLinkAny: String?
        private var rdfAbout: String?
        private var isAtom = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let lower = name.lowercased()
            if stack.isEmpty { sawFeed = ["rss", "feed", "rdf:rdf", "rdf", "channel"].contains(lower); isAtom = lower == "feed" }
            stack.append(lower)
            text = ""
            if lower == "item" || lower == "entry" {
                inEntry = true
                cur = [:]
                atomLinkAlternate = nil
                atomLinkAny = nil
                rdfAbout = attributes["rdf:about"]
            } else if lower == "link" {
                if let href = attributes["href"] {
                    let rel = attributes["rel"]?.lowercased() ?? "alternate"
                    if inEntry {
                        if rel == "alternate" { atomLinkAlternate = atomLinkAlternate ?? href }
                        atomLinkAny = atomLinkAny ?? href
                    } else if rel == "alternate", feedLink.isEmpty {
                        feedLink = href
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let lower = name.lowercased()
            defer { stack.removeLast(); text = "" }
            let value = text
            if inEntry {
                if lower == "item" || lower == "entry" {
                    inEntry = false
                    let link = atomLinkAlternate ?? cur["link"]?.trimmed ?? atomLinkAny ?? rdfAbout ?? cur["guid"]?.trimmed ?? ""
                    let id = cur["guid"]?.trimmed ?? cur["id"]?.trimmed ?? rdfAbout ?? link
                    let title = HTMLToMarkdown.text(cur["title"] ?? "").trimmed
                    guard !title.isEmpty || !link.isEmpty else { return }
                    let summary = cur["description"] ?? cur["summary"] ?? ""
                    let content = cur["content:encoded"] ?? cur["content"] ?? ""
                    let dateRaw = cur["pubdate"] ?? cur["published"] ?? cur["dc:date"] ?? cur["updated"] ?? cur["lastbuilddate"] ?? ""
                    let fields = cur
                    let author = ["dc:creator", "name", "author"].lazy.compactMap { fields[$0]?.trimmed }.first { !$0.isEmpty }
                    entries.append(FeedEntry(id: id.isEmpty ? title : id, title: title.isEmpty ? link : title, link: link,
                                             summary: HTMLToMarkdown.text(summary).trimmed, content: content.trimmed,
                                             author: author, published: FeedParser.date(dateRaw)))
                } else if lower == "name", stack.dropLast().last == "author" {
                    cur["name"] = value
                } else if ["title", "link", "guid", "id", "description", "summary", "content", "content:encoded", "pubdate", "published", "updated", "dc:date", "dc:creator", "author"].contains(lower) {
                    if cur[lower] == nil || (cur[lower]?.trimmed.isEmpty ?? true) { cur[lower] = value }
                }
            } else if stack.count <= 3 {
                if lower == "title", feedTitle.isEmpty { feedTitle = HTMLToMarkdown.text(value) }
                if lower == "link", !isAtom, feedLink.isEmpty { feedLink = value }
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
