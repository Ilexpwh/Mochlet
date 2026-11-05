import Foundation

/// `json_list` sources: a JSON document, a dot path to the array, dot paths to the title and the URL
/// (or a `{raw:field}` template), and a published-at path with its unit.
public enum JSONListMapper {
    public struct Config: Sendable, Equatable {
        public var url: String
        public var itemsPath: String
        public var titlePaths: [String]
        public var urlPath: String?
        public var urlTemplate: String?
        public var summaryPath: String?
        public var idPath: String?
        public var publishedAtPath: String?
        public var publishedAtUnit: String   // "s", "ms" or "iso"
        public init(url: String, itemsPath: String, titlePaths: [String], urlPath: String? = nil, urlTemplate: String? = nil, summaryPath: String? = nil,
                    idPath: String? = nil, publishedAtPath: String? = nil, publishedAtUnit: String = "iso") {
            self.url = url
            self.itemsPath = itemsPath
            self.titlePaths = titlePaths
            self.urlPath = urlPath
            self.urlTemplate = urlTemplate
            self.summaryPath = summaryPath
            self.idPath = idPath
            self.publishedAtPath = publishedAtPath
            self.publishedAtUnit = publishedAtUnit
        }

        public init?(_ c: [String: JSONValue]) {
            guard let url = c["url"]?.string else { return nil }
            let titles = c["titlePaths"]?.array?.compactMap(\.string) ?? c["titlePath"]?.string.map { [$0] } ?? ["title"]
            self.init(url: url, itemsPath: c["itemsPath"]?.string ?? "", titlePaths: titles, urlPath: c["urlPath"]?.string, urlTemplate: c["urlTemplate"]?.string,
                      summaryPath: c["summaryPath"]?.string, idPath: c["idPath"]?.string, publishedAtPath: c["publishedAtPath"]?.string, publishedAtUnit: c["publishedAtUnit"]?.string ?? "iso")
        }
    }

    public struct Item: Sendable, Equatable {
        public var id: String
        public var title: String
        public var url: String
        public var summary: String
        public var published: Date?
    }

    public static func value(_ json: JSONValue, path: String) -> JSONValue {
        guard !path.isEmpty, path != "." else { return json }
        var cur = json
        for part in path.split(separator: ".") {
            let p = String(part)
            if let i = Int(p) { cur = cur[i] } else { cur = cur[p] }
        }
        return cur
    }

    /// `{raw:field}` and `{field}` placeholders filled from the item.
    public static func fill(_ template: String, item: JSONValue) -> String {
        var out = template
        let re = try! NSRegularExpression(pattern: "\\{(raw:)?([A-Za-z0-9_.]+)\\}")
        let ns = out as NSString
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let key = ns.substring(with: m.range(at: 2))
            let v = value(item, path: key)
            let s = v.string ?? v.int.map(String.init) ?? v.double.map { String($0) } ?? ""
            out = (out as NSString).replacingCharacters(in: m.range, with: s)
        }
        return out
    }

    public static func items(_ json: JSONValue, config c: Config) -> [Item] {
        let list = value(json, path: c.itemsPath).array ?? []
        return list.compactMap { item in
            let title = c.titlePaths.lazy.compactMap { value(item, path: $0).string?.trimmed }.first { !$0.isEmpty } ?? ""
            var url = ""
            if let t = c.urlTemplate { url = fill(t, item: item) } else if let p = c.urlPath { url = value(item, path: p).string ?? "" } else { url = item["url"].string ?? item["link"].string ?? "" }
            guard !title.isEmpty, SignalText.isWebURL(url) else { return nil }
            let summary = c.summaryPath.flatMap { value(item, path: $0).string } ?? ""
            let id = c.idPath.flatMap { p -> String? in let v = value(item, path: p); return v.string ?? v.int.map(String.init) } ?? url
            var published: Date?
            if let p = c.publishedAtPath {
                let v = value(item, path: p)
                switch c.publishedAtUnit {
                case "s": published = v.double.map { Date(timeIntervalSince1970: $0) }
                case "ms": published = v.double.map { Date(timeIntervalSince1970: $0 / 1000) }
                default: published = v.string.flatMap(FeedParser.date) ?? v.double.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
                }
            }
            return Item(id: id, title: HTMLToMarkdown.text(title).trimmed, url: url, summary: HTMLToMarkdown.text(summary).trimmed, published: published)
        }
    }
}

/// `web_list` sources: a page, a selector for each item, and selectors for the link, the title and the date.
public enum WebListExtractor {
    public struct Config: Sendable, Equatable {
        public var url: String
        public var itemSelector: String
        public var linkSelector: String?
        public var titleSelector: String?
        public var summarySelector: String?
        public var publishedAtSelector: String?
        public var render: String     // auto | static | webview
        public init(url: String, itemSelector: String, linkSelector: String? = nil, titleSelector: String? = nil, summarySelector: String? = nil, publishedAtSelector: String? = nil, render: String = "auto") {
            self.url = url
            self.itemSelector = itemSelector
            self.linkSelector = linkSelector
            self.titleSelector = titleSelector
            self.summarySelector = summarySelector
            self.publishedAtSelector = publishedAtSelector
            self.render = render
        }
        public init?(_ c: [String: JSONValue]) {
            guard let url = c["url"]?.string, let item = c["itemSelector"]?.string, !item.isEmpty else { return nil }
            self.init(url: url, itemSelector: item, linkSelector: c["linkSelector"]?.string, titleSelector: c["titleSelector"]?.string,
                      summarySelector: c["summarySelector"]?.string, publishedAtSelector: c["publishedAtSelector"]?.string, render: c["render"]?.string ?? "auto")
        }
    }

    public struct Item: Sendable, Equatable {
        public var title: String
        public var url: String
        public var summary: String
        public var published: Date?
    }

    public static func items(html: String, baseURL: URL?, config c: Config) -> [Item] {
        let doc = HTMLDocument.parse(html)
        var out: [Item] = []
        var seen = Set<String>()
        for el in doc.select(c.itemSelector) {
            let link = c.linkSelector.flatMap { el.first($0) } ?? (el.name == "a" ? el : el.first("a[href]"))
            guard let href = link?.attr("href"), let url = resolve(href, base: baseURL) else { continue }
            var title = c.titleSelector.flatMap { el.first($0)?.text } ?? link?.text ?? ""
            if title.isEmpty { title = el.text }
            title = String(title.prefix(300)).trimmed
            guard title.count >= 4, !seen.contains(url) else { continue }
            seen.insert(url)
            let summary = c.summarySelector.flatMap { el.first($0)?.text } ?? ""
            var published: Date?
            if let ps = c.publishedAtSelector, let d = el.first(ps) { published = FeedParser.date(d.attr("datetime") ?? d.attr("title") ?? d.text) }
            out.append(Item(title: title, url: url, summary: summary, published: published))
        }
        return out
    }

    public static func resolve(_ href: String, base: URL?) -> String? {
        let h = href.trimmed
        guard !h.isEmpty, !h.hasPrefix("#"), !h.lowercased().hasPrefix("javascript:"), !h.lowercased().hasPrefix("mailto:") else { return nil }
        if let u = URL(string: h), u.scheme != nil { return SignalText.isWebURL(u.absoluteString) ? u.absoluteString : nil }
        guard let base, let u = URL(string: h, relativeTo: base)?.absoluteURL, SignalText.isWebURL(u.absoluteString) else { return nil }
        return u.absoluteString
    }
}

/// What a page looks like as a source: its feeds, or a guess at the repeated list on it.
public enum SourceDetector {
    public struct Guess: Sendable, Equatable {
        public var feeds: [(title: String, url: String)]
        public var list: ListGuess?
        public static func == (l: Guess, r: Guess) -> Bool { l.feeds.map(\.url) == r.feeds.map(\.url) && l.list == r.list }
    }
    public struct ListGuess: Sendable, Equatable {
        public var itemSelector: String
        public var linkSelector: String
        public var count: Int
        public var samples: [String]
    }

    public static let feedPaths = ["/feed", "/rss", "/rss.xml", "/atom.xml", "/feed.xml", "/index.xml", "/feed/", "/rss/"]

    public static func looksLikeFeed(contentType: String?, body: Data) -> Bool {
        if let ct = contentType?.lowercased(), ct.contains("rss") || ct.contains("atom") || ct.contains("xml") {
            return FeedParser.parse(body) != nil
        }
        let head = String(decoding: body.prefix(600), as: UTF8.self).lowercased()
        return (head.contains("<rss") || head.contains("<feed") || head.contains("<rdf:rdf")) && FeedParser.parse(body) != nil
    }

    public static func guess(html: String, baseURL: URL?) -> Guess {
        let doc = HTMLDocument.parse(html)
        var feeds: [(String, String)] = []
        for l in doc.select("link") {
            guard l.attr("rel")?.lowercased().contains("alternate") == true, let type = l.attr("type")?.lowercased(), type.contains("rss") || type.contains("atom"),
                  let href = l.attr("href"), let url = WebListExtractor.resolve(href, base: baseURL) else { continue }
            feeds.append((l.attr("title") ?? "Feed", url))
        }
        // The list: the parent signature shared by the most text-bearing links.
        var groups: [String: [HTMLElement]] = [:]
        for a in doc.select("a[href]") {
            guard a.text.count >= 15, let parent = a.parent else { continue }
            let container = parent.name == "h1" || parent.name == "h2" || parent.name == "h3" || parent.name == "span" ? (parent.parent ?? parent) : parent
            groups[container.signature, default: []].append(container)
        }
        var list: ListGuess?
        if let best = groups.max(by: { $0.value.count < $1.value.count }), best.value.count >= 5 {
            let unique = Array(NSOrderedSet(array: best.value).array as! [HTMLElement])
            if unique.count >= 5 {
                let samples = unique.prefix(5).compactMap { $0.first("a[href]")?.text }.map { String($0.prefix(80)) }
                list = ListGuess(itemSelector: best.key, linkSelector: "a", count: unique.count, samples: samples)
            }
        }
        return Guess(feeds: feeds, list: list)
    }
}
