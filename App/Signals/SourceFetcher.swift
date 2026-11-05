import Foundation
import MochletCore
import MochletServices

/// One HTTP fetch for the signals engine: conditional on the validators of the last fetch, public
/// hosts only (redirects included), capped in size, with a desktop user agent.
enum SignalFetch {
    struct Result: Sendable {
        var data: Data
        var status: Int
        var etag: String?
        var lastModified: String?
        var contentType: String?
        var charset: String?
        var finalURL: URL
        var notModified: Bool { status == 304 }
        var text: String { StaticFetcher.decode(data, charset: charset) }
    }

    /// `publicOnly` gates the host and every redirect (for URLs that did not come from the user's own
    /// configuration, such as items pushed in by another program); sources.json is the user's choice.
    static func get(_ url: URL, etag: String? = nil, lastModified: String? = nil, accept: String? = nil, headers: [String: String] = [:],
                    maxBytes: Int = 5_000_000, publicOnly: Bool = false) async throws -> Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { throw SignalFetchError.noResponse(url.absoluteString) }
        if publicOnly, !(await HostPolicy.allows(url)) { throw SignalFetchError.privateHost(url.host ?? "") }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let guardian = publicOnly ? RedirectGuard() : nil
        let (data, resp) = try await StaticFetcher.session.data(for: req, delegate: guardian)
        if guardian?.sawPrivateAddress == true { throw SignalFetchError.privateHost(url.host ?? "") }
        guard let http = resp as? HTTPURLResponse else { throw SignalFetchError.noResponse(url.host ?? "") }
        if http.statusCode == 304 {
            return Result(data: Data(), status: 304, etag: etag, lastModified: lastModified, contentType: nil, charset: nil, finalURL: http.url ?? url)
        }
        guard (200..<300).contains(http.statusCode) else { throw SignalFetchError.status(http.statusCode, url.host ?? "") }
        guard data.count <= maxBytes else { throw SignalFetchError.tooLarge }
        return Result(data: data, status: http.statusCode,
                      etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                      contentType: http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), charset: http.textEncodingName, finalURL: http.url ?? url)
    }
}

enum SignalFetchError: LocalizedError {
    case privateHost(String), noResponse(String), status(Int, String), tooLarge, notAFeed(String), badConfig(String), needsKey(String), nothing

    var errorDescription: String? {
        switch self {
        case .privateHost(let h): return "\(h) is not a public host."
        case .noResponse(let h): return "No HTTP response from \(h)."
        case .status(let s, let h): return "\(h) answered \(s)."
        case .tooLarge: return "The response is too large."
        case .notAFeed(let h): return "\(h) did not return an RSS or Atom feed."
        case .badConfig(let what): return "The source is missing \(what)."
        case .needsKey(let what): return "\(what) needs an API key (Settings → Signals)."
        case .nothing: return "Nothing to fetch for this kind of source."
        }
    }
}

/// Items a source yields now, by kind: RSS/Atom, a JSON list, a web list (static HTML or the hidden
/// web view), an AIHOT instance's feeds, an X search through SocialData. External sources are fed by
/// the push endpoint and the watch folder instead.
enum SourceFetcher {
    struct Keys: Sendable {
        var socialData: String?
    }

    struct Pulled: Sendable {
        var items: [SignalItem]
        var etag: String?
        var lastModified: String?
        var notModified = false
    }

    static let feedAccept = "application/rss+xml, application/atom+xml, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, */*;q=0.5"

    static func pull(_ source: SignalSource, state: SignalsStore.SourceState, keys: Keys, now: Date = Date()) async throws -> Pulled {
        switch source.kind {
        case .rss:
            guard let s = source.url, let url = URL(string: s) else { throw SignalFetchError.badConfig("feedUrl") }
            return try await feed(url, source: source, state: state, now: now)
        case .aihot:
            let urls = AIHOTImport.feedURLs(source)
            guard !urls.isEmpty else { throw SignalFetchError.badConfig("baseUrl") }
            var all: [SignalItem] = []
            var firstError: Error?
            for u in urls {
                do { all += try await feed(u, source: source, state: SignalsStore.SourceState(), now: now).items } catch { firstError = firstError ?? error }
            }
            if all.isEmpty, let firstError { throw firstError }
            var seen = Set<String>()
            return Pulled(items: all.filter { seen.insert($0.id).inserted })
        case .jsonList:
            guard let c = JSONListMapper.Config(source.config), let url = URL(string: c.url) else { throw SignalFetchError.badConfig("url / itemsPath") }
            let r = try await SignalFetch.get(url, etag: state.etag, lastModified: state.lastModified, accept: "application/json, */*;q=0.5")
            if r.notModified { return Pulled(items: [], etag: r.etag, lastModified: r.lastModified, notModified: true) }
            guard let json = JSONValue.parse(r.data) else { throw SignalFetchError.badConfig("a JSON body at \(url.host ?? "url")") }
            let items = JSONListMapper.items(json, config: c).map { it in
                SignalItem(sourceID: source.id, externalID: it.id, url: it.url, title: it.title, summary: it.summary, publishedAt: it.published, discoveredAt: now)
            }
            return Pulled(items: items, etag: r.etag, lastModified: r.lastModified)
        case .webList:
            guard let c = WebListExtractor.Config(source.config), let url = URL(string: c.url) else { throw SignalFetchError.badConfig("url / itemSelector") }
            let render = source.config["render"]?.string ?? c.render
            var html = ""
            var etag: String?, lastModified: String?
            var base = url
            if render != "webview" {
                let r = try await SignalFetch.get(url, etag: state.etag, lastModified: state.lastModified, accept: "text/html, */*;q=0.5")
                if r.notModified { return Pulled(items: [], etag: r.etag, lastModified: r.lastModified, notModified: true) }
                html = r.text
                etag = r.etag
                lastModified = r.lastModified
                base = r.finalURL
            }
            var found = html.isEmpty ? [] : WebListExtractor.items(html: html, baseURL: base, config: c)
            if found.isEmpty, render != "static" {
                // Nothing in the static HTML: the page builds its list with scripts, so render it.
                let page = try await WebReader.shared.read(url, publicOnly: false)
                found = WebListExtractor.items(html: page.html, baseURL: page.finalURL, config: c)
            }
            let items = found.map { it in
                SignalItem(sourceID: source.id, externalID: it.url, url: it.url, title: it.title, summary: it.summary, publishedAt: it.published, discoveredAt: now)
            }
            return Pulled(items: items, etag: etag, lastModified: lastModified)
        case .xSearch:
            guard let key = keys.socialData, !key.isEmpty else { throw SignalFetchError.needsKey("X search (SocialData)") }
            guard let query = source.config["query"]?.string, !query.isEmpty else { throw SignalFetchError.badConfig("query") }
            var comps = URLComponents(string: "https://api.socialdata.tools/twitter/search")!
            comps.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: source.config["searchType"]?.string ?? "Latest")]
            let r = try await SignalFetch.get(comps.url!, accept: "application/json", headers: ["Authorization": "Bearer \(key)"])
            guard let json = JSONValue.parse(r.data) else { throw SignalFetchError.badConfig("a JSON answer from SocialData") }
            return Pulled(items: tweets(json, source: source, now: now))
        case .external, .mpAccount:
            throw SignalFetchError.nothing
        }
    }

    static func feed(_ url: URL, source: SignalSource, state: SignalsStore.SourceState, now: Date) async throws -> Pulled {
        let r = try await SignalFetch.get(url, etag: state.etag, lastModified: state.lastModified, accept: feedAccept)
        if r.notModified { return Pulled(items: [], etag: r.etag, lastModified: r.lastModified, notModified: true) }
        guard let feed = FeedParser.parse(r.data) else { throw SignalFetchError.notAFeed(url.host ?? url.absoluteString) }
        let items = feed.entries.compactMap { e -> SignalItem? in
            guard !e.link.isEmpty || !e.title.isEmpty else { return nil }
            let link = e.link.isEmpty ? "" : (WebListExtractor.resolve(e.link, base: r.finalURL) ?? e.link)
            let body = e.content.isEmpty ? "" : String(HTMLToMarkdown.convert(e.content, baseURL: URL(string: link)).prefix(8000))
            let summary = e.summary.isEmpty ? String(HTMLToMarkdown.text(e.content).trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) : String(e.summary.prefix(1200))
            return SignalItem(sourceID: source.id, externalID: e.id, url: link, title: e.title, summary: summary, body: body, author: e.author,
                              publishedAt: e.published, discoveredAt: now)
        }
        return Pulled(items: items, etag: r.etag, lastModified: r.lastModified)
    }

    /// SocialData's search answer: `{"tweets": [{id_str, full_text, tweet_created_at, user: {screen_name}}]}`.
    static func tweets(_ json: JSONValue, source: SignalSource, now: Date) -> [SignalItem] {
        let list = json["tweets"].array ?? json["data"].array ?? []
        return list.compactMap { t in
            guard let id = t["id_str"].string ?? t["id"].string, let text = t["full_text"].string ?? t["text"].string, !text.isEmpty else { return nil }
            let user = t["user"]["screen_name"].string ?? t["user"]["username"].string ?? "i"
            let url = "https://x.com/\(user)/status/\(id)"
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            let title = String(firstLine.prefix(140))
            let created = (t["tweet_created_at"].string ?? t["created_at"].string).flatMap { FeedParser.date($0) ?? twitterDate($0) }
            return SignalItem(sourceID: source.id, externalID: id, url: url, title: title, summary: text, author: "@" + user, publishedAt: created, discoveredAt: now)
        }
    }

    static func twitterDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f.date(from: s)
    }

    /// Body text for items whose feed gave only a blurb (T1 / T1.5 only): the page's main content.
    static func body(for url: URL, publicOnly: Bool) async throws -> String {
        let r = try await SignalFetch.get(url, accept: "text/html, */*;q=0.5", maxBytes: 3_000_000, publicOnly: publicOnly)
        guard r.contentType?.contains("html") ?? true else { return "" }
        return String(HTMLToMarkdown.convert(ReaderHeuristics.mainContent(r.text), baseURL: url).prefix(6000))
    }

    /// What a URL is: a feed, a page with feeds or a list the extractor can read.
    struct Detection: Sendable {
        var url: String
        var feedTitle: String?
        var feedCount: Int
        var feeds: [(url: String, title: String)]
        var list: SourceDetector.ListGuess?
        var error: String?
    }

    static func detect(_ raw: String) async -> Detection {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return Detection(url: text, feedCount: 0, feeds: [], error: "Not a URL.") }
        do {
            let r = try await SignalFetch.get(url, accept: feedAccept)
            if SourceDetector.looksLikeFeed(contentType: r.contentType, body: r.data), let feed = FeedParser.parse(r.data) {
                return Detection(url: r.finalURL.absoluteString, feedTitle: feed.title, feedCount: feed.entries.count, feeds: [])
            }
            if let json = JSONValue.parse(r.data), r.contentType?.contains("json") == true, let list = json.array ?? json["items"].array ?? json["data"].array, !list.isEmpty {
                return Detection(url: r.finalURL.absoluteString, feedCount: 0, feeds: [], error: "A JSON list (\(list.count) entries): add it as a json_list source in sources.json with itemsPath/titlePaths/urlPath.")
            }
            let html = r.text
            var guess = SourceDetector.guess(html: html, baseURL: r.finalURL)
            if guess.feeds.isEmpty {
                // Probe the usual feed paths.
                for path in SourceDetector.feedPaths {
                    guard let probe = URL(string: path, relativeTo: r.finalURL)?.absoluteURL else { continue }
                    if let pr = try? await SignalFetch.get(probe, accept: feedAccept, maxBytes: 2_000_000), SourceDetector.looksLikeFeed(contentType: pr.contentType, body: pr.data), let f = FeedParser.parse(pr.data), !f.entries.isEmpty {
                        guess.feeds.append((title: f.title, url: pr.finalURL.absoluteString))
                        break
                    }
                }
            }
            return Detection(url: r.finalURL.absoluteString, feedCount: 0, feeds: guess.feeds.map { (url: $0.url, title: $0.title) }, list: guess.list)
        } catch {
            return Detection(url: text, feedCount: 0, feeds: [], error: ErrorText.describe(error))
        }
    }
}
