import AppKit
import Foundation
import WebKit
import MochletCore
import MochletServices

enum WebReaderError: Error, CustomStringConvertible {
    case privateHost(String)
    case timeout
    case notHTML(String)
    case isPDF(URL)
    case failed(String)
    case tooLarge
    case robots(String)
    var description: String {
        switch self {
        case .timeout: return "The page did not finish loading in time."
        case .privateHost(let h): return "\(h.isEmpty ? "That address" : h) is not on the public internet; agents may only ask for public links."
        case .notHTML(let t): return "Not a web page (\(t))."
        case .isPDF: return "The link is a PDF."
        case .failed(let s): return s
        case .tooLarge: return "The page is larger than 10 MB."
        case .robots(let h): return "\(h) asks crawlers not to read that page (robots.txt); turn the check off in Settings → Knowledge to read it anyway."
        }
    }
}

/// What the reader script pulls out of a rendered page.
struct ReaderArticle: Sendable {
    var title: String
    var byline: String?
    var published: String?
    var siteName: String?
    var excerpt: String?
    var lang: String?
    var contentHTML: String
    var textLength: Int
}

/// Renders a page in a hidden WKWebView (JavaScript on, nothing persisted, Safari's user agent),
/// waits for the DOM to settle, runs Mochlet's own reader script and hands back the article HTML
/// plus a snapshot of the whole document for `references/`. One page at a time, 25 s cap.
@MainActor
final class WebReader: NSObject, WKNavigationDelegate {
    static let shared = WebReader()

    struct Page: Sendable {
        var finalURL: URL
        var html: String
        var article: ReaderArticle
    }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var navigation: CheckedContinuation<Void, Error>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pdfHit: URL?
    private var publicOnly = false

    func read(_ url: URL, timeout: Double = 25, publicOnly: Bool = false) async throws -> Page {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        if publicOnly, !(await HostPolicy.allows(url)) { throw WebReaderError.privateHost(url.host ?? "") }
        self.publicOnly = publicOnly
        let web = makeWebView()
        pdfHit = nil
        try await load(url, in: web, timeout: timeout)
        if let pdf = pdfHit { throw WebReaderError.isPDF(pdf) }
        await settle(web, maxWait: 3)
        let finalURL = web.url ?? url
        let json = (try? await evaluate(Self.readerScript, in: web)) ?? "{}"
        let v = JSONValue.parse(json) ?? .null
        let article = ReaderArticle(title: Self.clean(v["title"].string) ?? web.title ?? url.host ?? "page", byline: Self.clean(v["byline"].string), published: Self.clean(v["published"].string),
                                    siteName: Self.clean(v["siteName"].string), excerpt: Self.clean(v["excerpt"].string), lang: Self.clean(v["lang"].string),
                                    contentHTML: v["content"].string ?? "", textLength: v["length"].int ?? 0)
        let html = (try? await evaluate("document.documentElement.outerHTML", in: web)) ?? ""
        web.load(URLRequest(url: URL(string: "about:blank")!))
        if html.utf8.count > 10_000_000 { throw WebReaderError.tooLarge }
        return Page(finalURL: finalURL, html: html, article: article)
    }

    private static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        web.navigationDelegate = self
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = web
        window = win
        webView = web
        return web
    }

    private func load(_ url: URL, in web: WKWebView, timeout: Double) async throws {
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, let c = self.navigation else { return }
            self.navigation = nil
            web.stopLoading()
            c.resume(throwing: WebReaderError.timeout)
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navigation = c
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        }
    }

    /// Waits until the visible text stops growing (SPAs render after `didFinish`), at most `maxWait` s.
    private func settle(_ web: WKWebView, maxWait: Double) async {
        var last = -1
        var stable = 0
        let steps = Int(maxWait / 0.4)
        for _ in 0..<max(1, steps) {
            try? await Task.sleep(for: .milliseconds(400))
            let n = Int((try? await evaluate("String(document.body ? document.body.innerText.length : 0)", in: web)) ?? "0") ?? 0
            if n == last, n > 0 { stable += 1 } else { stable = 0 }
            last = n
            if stable >= 1 { break }
        }
    }

    private func evaluate(_ js: String, in web: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            web.evaluateJavaScript(js) { result, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: (result as? String) ?? (result.map { "\($0)" } ?? "")) }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let c = navigation else { return }
        navigation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(WebReaderError.failed(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled, pdfHit != nil { finish(nil); return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(WebReaderError.failed(error.localizedDescription))
    }

    /// Agent-requested reads may not follow redirects or frames into private networks.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard publicOnly, let url = navigationAction.request.url, url.scheme != "about" else { return .allow }
        if await HostPolicy.allows(url) { return .allow }
        if navigationAction.targetFrame?.isMainFrame ?? true {
            navigation.map { c in
                navigation = nil
                c.resume(throwing: WebReaderError.privateHost(url.host ?? ""))
            }
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
        if mime == "application/pdf" {
            pdfHit = navigationResponse.response.url
            return .cancel
        }
        if !mime.isEmpty, !mime.contains("html"), !mime.contains("xml"), !mime.hasPrefix("text/") {
            pdfHit = nil
            navigation.map { c in
                navigation = nil
                c.resume(throwing: WebReaderError.notHTML(mime))
            }
            return .cancel
        }
        return .allow
    }

    // MARK: Reader script (Mochlet's own; no third-party code)

    static let readerScript = #"""
    (function () {
      function txt(el) { return (el && (el.innerText || el.textContent) || '').replace(/\s+/g, ' ').trim(); }
      function meta(sel) { var m = document.querySelector(sel); return m ? (m.getAttribute('content') || '').trim() : ''; }
      var NEG = /comment|sidebar|footer|nav|menu|share|related|promo|advert|banner|cookie|subscribe|popup|modal|social|breadcrumb|widget|toolbar|login|signup|recommend|newsletter/i;
      var POS = /article|content|post|entry|main|body|text|story|blog|markdown|readme|wiki|doc|abstract|paper/i;
      var cands = [], seen = new Set();
      ['article', 'main', '[role=main]', '[itemprop=articleBody]', '.post-content', '.entry-content', '.article-content', '.markdown-body', '#content', '.content', 'section', 'div'].forEach(function (s) {
        try { document.querySelectorAll(s).forEach(function (e) { if (!seen.has(e)) { seen.add(e); cands.push(e); } }); } catch (_) {}
      });
      function cls(e) { var c = (typeof e.className === 'string' ? e.className : '') + ' ' + (e.id || ''); return c; }
      function score(e) {
        var t = txt(e), len = t.length; if (len < 200) return -1;
        var links = 0; e.querySelectorAll('a').forEach(function (a) { links += txt(a).length; });
        var density = links / Math.max(1, len);
        var ps = e.querySelectorAll('p').length;
        var s = len * (1 - density) * (1 - density) + ps * 50;
        var c = cls(e); if (NEG.test(c)) s *= 0.3; if (POS.test(c)) s *= 1.3;
        if (e.tagName === 'ARTICLE' || e.tagName === 'MAIN' || e.getAttribute('role') === 'main') s *= 1.5;
        return s;
      }
      var best = null, bestScore = 0;
      cands.forEach(function (e) { var s = score(e); if (s > bestScore) { bestScore = s; best = e; } });
      if (best) { var bl = txt(best).length; cands.forEach(function (e) { if (e !== best && best.contains(e)) { var l = txt(e).length; if (l >= 0.7 * bl && score(e) > 0) { best = e; bl = l; } } }); }
      if (!best) best = document.body || document.documentElement;
      var clone = best.cloneNode(true);
      clone.querySelectorAll('script,style,noscript,iframe,svg,canvas,form,button,input,select,textarea,nav,aside,footer,header,[role=navigation],[role=banner],[role=complementary],[aria-hidden=true]').forEach(function (x) { x.remove(); });
      clone.querySelectorAll('div,section,ul,ol').forEach(function (x) { if (NEG.test(cls(x)) && txt(x).length < 400) x.remove(); });
      var h1 = document.querySelector('h1');
      var title = meta('meta[property="og:title"]') || (h1 ? txt(h1) : '') || document.title || '';
      var by = document.querySelector('[rel=author],.byline,.author,[itemprop=author]');
      var byline = meta('meta[name="author"]') || meta('meta[property="article:author"]') || (by ? txt(by) : '');
      var tEl = document.querySelector('time[datetime]');
      var published = meta('meta[property="article:published_time"]') || meta('meta[name="date"]') || meta('meta[name="pubdate"]') || (tEl ? (tEl.getAttribute('datetime') || '') : '');
      var site = meta('meta[property="og:site_name"]') || location.hostname;
      var excerpt = meta('meta[name="description"]') || meta('meta[property="og:description"]');
      var lang = document.documentElement.lang || '';
      return JSON.stringify({ title: title, byline: byline, published: published, siteName: site, excerpt: excerpt, lang: lang, content: clone.innerHTML, length: txt(clone).length, url: location.href });
    })();
    """#
}

/// robots.txt per host, cached for a day; unreachable or missing files allow everything.
actor RobotsCache {
    static let shared = RobotsCache()
    private var rules: [String: (Date, RobotsRules)] = [:]

    func allows(_ url: URL) async -> Bool {
        guard let host = url.host, let scheme = url.scheme else { return true }
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?" + $0 } ?? "")
        if let (at, r) = rules[host], Date().timeIntervalSince(at) < 86_400 { return r.allows(path: path) }
        var r = RobotsRules.parse("")
        if let robots = URL(string: "\(scheme)://\(host)/robots.txt") {
            var req = URLRequest(url: robots, timeoutInterval: 8)
            req.setValue("Mochlet/2.0 (personal knowledge base; +https://github.com/Ilexpwh/Mochlet)", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await StaticFetcher.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 512_000, let text = String(data: data, encoding: .utf8) {
                r = RobotsRules.parse(text)
            }
        }
        rules[host] = (Date(), r)
        return r.allows(path: path)
    }
}

/// Plain HTTP fetches with a desktop user agent, a 25 s timeout and size caps.
enum StaticFetcher {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 60
        c.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                                   "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ",")]
        return URLSession(configuration: c)
    }()

    static func data(_ url: URL, accept: String? = nil, maxBytes: Int = 10_000_000, publicOnly: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        if publicOnly, !(await HostPolicy.allows(url)) { throw WebReaderError.privateHost(url.host ?? "") }
        let (data, resp) = try await session.data(for: req, delegate: publicOnly ? RedirectGuard.shared : nil)
        guard let http = resp as? HTTPURLResponse else { throw WebReaderError.failed("No HTTP response from \(url.host ?? "server")") }
        guard (200..<300).contains(http.statusCode) else { throw WebReaderError.failed("\(url.host ?? "server") answered \(http.statusCode)") }
        guard data.count <= maxBytes else { throw WebReaderError.tooLarge }
        return (data, http)
    }

    static func text(_ url: URL, accept: String? = nil, maxBytes: Int = 10_000_000, publicOnly: Bool = false) async throws -> String {
        let (data, http) = try await data(url, accept: accept, maxBytes: maxBytes, publicOnly: publicOnly)
        return decode(data, charset: http.textEncodingName)
    }

    /// Text from a response body: the declared charset (IANA name) when it is known, else UTF-8 with replacement.
    static func decode(_ data: Data, charset: String?) -> String {
        if let name = charset, !name.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Downloads to a temp file named after the URL (so the mirror keeps a readable name); 100 MB cap.
    static func download(_ url: URL, suggestedName: String, maxBytes: Int = 100_000_000, publicOnly: Bool = false) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("application/pdf,*/*", forHTTPHeaderField: "Accept")
        if publicOnly, !(await HostPolicy.allows(url)) { throw WebReaderError.privateHost(url.host ?? "") }
        let (tmp, resp) = try await session.download(for: req, delegate: publicOnly ? RedirectGuard.shared : nil)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tmp)
            throw WebReaderError.failed("\(url.host ?? "server") answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else { try? FileManager.default.removeItem(at: tmp); throw WebReaderError.tooLarge }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mochlet-downloads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(suggestedName)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
