import Foundation

/// A tolerant HTML → Markdown converter (no external parser): headings, paragraphs, lists, links,
/// images, emphasis, code, blockquotes, simple tables; scripts, styles, navigation and forms dropped.
public enum HTMLToMarkdown {
    struct Tag {
        var name: String
        var attrs: [String: String]
        var closing: Bool
        var selfClosing: Bool
    }

    public static func convert(_ html: String, baseURL: URL? = nil) -> String {
        var out = ""
        var listStack: [(ordered: Bool, index: Int)] = []
        var skipDepth = 0
        var preDepth = 0
        var pendingLink: (href: String, start: String.Index)? = nil
        var inTable = false
        var rowCells: [String] = []
        var tableRows: [[String]] = []
        var cellBuffer = ""
        var inCell = false
        var headerRowSeen = false

        func append(_ s: String) {
            if inCell { cellBuffer += s } else { out += s }
        }
        func ensureBlankLine() {
            if inCell { return }
            while out.hasSuffix("\n\n\n") { out.removeLast() }
            if out.isEmpty { return }
            if !out.hasSuffix("\n\n") { out += out.hasSuffix("\n") ? "\n" : "\n\n" }
        }
        func resolve(_ href: String) -> String {
            guard let baseURL, let u = URL(string: href, relativeTo: baseURL) else { return href }
            return u.absoluteURL.absoluteString
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let width = tableRows.map(\.count).max() ?? 0
            guard width > 0 else { tableRows = []; return }
            ensureBlankLine()
            for (i, row) in tableRows.enumerated() {
                let cells = row + Array(repeating: "", count: width - row.count)
                out += "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n"
                if i == 0 { out += "|" + String(repeating: " --- |", count: width) + "\n" }
            }
            out += "\n"
            tableRows = []
        }

        var i = html.startIndex
        let skipTags: Set<String> = ["script", "style", "noscript", "svg", "iframe", "form", "button", "select", "nav", "footer", "aside", "template", "head", "canvas", "video", "audio", "object"]
        while i < html.endIndex {
            let c = html[i]
            if c == "<" {
                if html[i...].hasPrefix("<!--") {
                    if let end = html.range(of: "-->", range: i..<html.endIndex) { i = end.upperBound } else { i = html.endIndex }
                    continue
                }
                guard let close = html[i...].firstIndex(of: ">") else { break }
                let raw = String(html[html.index(after: i)..<close])
                i = html.index(after: close)
                guard let tag = parseTag(raw) else { continue }
                let name = tag.name
                if skipTags.contains(name) {
                    if tag.selfClosing { continue }
                    if tag.closing { skipDepth = max(0, skipDepth - 1) } else { skipDepth += 1 }
                    continue
                }
                if skipDepth > 0 { continue }
                if preDepth > 0, !(name == "pre" && tag.closing), name != "code" {
                    continue
                }
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    let level = Int(String(name.last!)) ?? 1
                    if tag.closing { append("\n\n") } else { ensureBlankLine(); append(String(repeating: "#", count: level) + " ") }
                case "p", "div", "section", "article", "main", "header", "figure", "figcaption", "dd", "dt", "dl", "details", "summary":
                    if tag.closing { if !inCell { ensureBlankLine() } } else { if !inCell { ensureBlankLine() } }
                case "br":
                    append(inCell ? " " : "\n")
                case "hr":
                    ensureBlankLine(); append("---\n\n")
                case "ul", "ol":
                    if tag.closing { if !listStack.isEmpty { listStack.removeLast() }; if listStack.isEmpty { ensureBlankLine() } }
                    else { if listStack.isEmpty { ensureBlankLine() } ; listStack.append((name == "ol", 0)) }
                case "li":
                    if tag.closing { append("\n") }
                    else {
                        if !out.hasSuffix("\n") { append("\n") }
                        let depth = max(0, listStack.count - 1)
                        var marker = "- "
                        if let last = listStack.last, last.ordered {
                            listStack[listStack.count - 1].index += 1
                            marker = "\(listStack[listStack.count - 1].index). "
                        }
                        append(String(repeating: "  ", count: depth) + marker)
                    }
                case "a":
                    if tag.closing {
                        if let link = pendingLink {
                            let text = String(out[link.start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !inCell {
                                out.removeSubrange(link.start...)
                                if text.isEmpty { out += link.href } else if text == link.href { out += "<\(link.href)>" } else { out += "[\(text)](\(link.href))" }
                            }
                            pendingLink = nil
                        }
                    } else if let href = tag.attrs["href"], !href.hasPrefix("#"), !href.hasPrefix("javascript:"), !inCell {
                        pendingLink = (resolve(href), out.endIndex)
                    }
                case "img":
                    let alt = tag.attrs["alt"] ?? ""
                    if let src = tag.attrs["src"], !src.hasPrefix("data:") { append("![\(alt)](\(resolve(src)))") } else if !alt.isEmpty { append("[\(alt)]") }
                case "strong", "b":
                    append("**")
                case "em", "i":
                    append("_")
                case "code":
                    if preDepth == 0 { append("`") }
                    else if !tag.closing, let lang = Self.fenceLanguage(tag.attrs["class"]), out.hasSuffix("```\n") { out.removeLast(); out += lang + "\n" }
                case "pre":
                    if tag.closing { preDepth = max(0, preDepth - 1); append("\n```\n\n") }
                    else { ensureBlankLine(); preDepth += 1; append("```" + (Self.fenceLanguage(tag.attrs["class"]) ?? "") + "\n") }
                case "blockquote":
                    if tag.closing { ensureBlankLine() } else { ensureBlankLine(); append("> ") }
                case "table":
                    if tag.closing { if inCell { rowCells.append(cellBuffer); inCell = false }; if !rowCells.isEmpty { tableRows.append(rowCells); rowCells = [] }; inTable = false; flushTable() }
                    else { ensureBlankLine(); inTable = true; tableRows = []; headerRowSeen = false }
                case "tr":
                    if inTable {
                        if tag.closing { if inCell { rowCells.append(cellBuffer); inCell = false }; tableRows.append(rowCells); rowCells = [] }
                        else { rowCells = [] }
                    }
                case "td", "th":
                    if inTable {
                        if tag.closing { rowCells.append(cellBuffer.trimmingCharacters(in: .whitespacesAndNewlines)); inCell = false; cellBuffer = "" }
                        else { if inCell { rowCells.append(cellBuffer) }; inCell = true; cellBuffer = ""; if name == "th" { headerRowSeen = true } }
                    }
                case "title", "meta", "link":
                    if name == "title", !tag.closing, !tag.selfClosing {
                        if let end = html.range(of: "</title>", options: .caseInsensitive, range: i..<html.endIndex) { i = end.upperBound }
                    }
                default:
                    break
                }
                continue
            }
            if skipDepth > 0 { i = html.index(after: i); continue }
            // Text run until the next tag.
            let next = html[i...].firstIndex(of: "<") ?? html.endIndex
            var text = String(html[i..<next])
            i = next
            text = decodeEntities(text)
            if preDepth == 0 {
                text = text.replacingOccurrences(of: "\r", with: "")
                text = text.replacingOccurrences(of: #"[ \t\n]+"#, with: " ", options: .regularExpression)
                if (out.hasSuffix("\n") || out.isEmpty) && !inCell { text = String(text.drop(while: { $0 == " " })) }
            }
            append(text)
        }
        _ = headerRowSeen
        flushTable()
        return tidy(out)
    }

    static func parseTag(_ raw: String) -> Tag? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("!"), !s.hasPrefix("?") else { return nil }
        var closing = false
        if s.hasPrefix("/") { closing = true; s.removeFirst() }
        var selfClosing = false
        if s.hasSuffix("/") { selfClosing = true; s.removeLast() }
        let nameEnd = s.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) ?? s.endIndex
        let name = s[..<nameEnd].lowercased()
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        var attrs: [String: String] = [:]
        if !closing, nameEnd < s.endIndex {
            let rest = String(s[nameEnd...])
            let re = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?"#)
            for m in re.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                guard let kr = Range(m.range(at: 1), in: rest) else { continue }
                let key = rest[kr].lowercased()
                var value = ""
                for g in 2...4 { if let r = Range(m.range(at: g), in: rest) { value = String(rest[r]); break } }
                attrs[key] = decodeEntities(value)
            }
        }
        if ["br", "img", "hr", "meta", "link", "input", "source", "wbr"].contains(name) { selfClosing = true }
        return Tag(name: name, attrs: attrs, closing: closing, selfClosing: selfClosing)
    }

    static let namedEntities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "hellip": "…",
                                                  "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "times": "×", "deg": "°", "euro": "€", "pound": "£", "yen": "¥"]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                if body.hasPrefix("#x") || body.hasPrefix("#X"), let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u); i = s.index(after: semi); continue }
                if body.hasPrefix("#"), let v = UInt32(body.dropFirst()), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u); i = s.index(after: semi); continue }
                if let e = namedEntities[body] { out += e; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    /// `language-swift`, `lang-py`, `highlight-source-js` → the fence info string.
    static func fenceLanguage(_ cls: String?) -> String? {
        guard let cls else { return nil }
        for token in cls.split(separator: " ") {
            for prefix in ["language-", "lang-", "highlight-source-", "brush:"] where token.hasPrefix(prefix) {
                let l = token.dropFirst(prefix.count).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                if !l.isEmpty { return String(l) }
            }
        }
        return nil
    }

    static func tidy(_ s: String) -> String {
        var lines = s.replacingOccurrences(of: "\u{00A0}", with: " ").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // collapse 3+ blank lines, drop empty emphasis, trim (list indentation and code stay as they are)
        var out: [String] = []
        var blank = 0
        var inFence = false
        let listItem = try! NSRegularExpression(pattern: #"^\s+(?:[-*+]|\d+\.)\s"#)
        for raw in lines {
            var l = raw
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); l = l.trimmingCharacters(in: .whitespaces) }
            else if !inFence {
                let indented = listItem.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil
                l = indented ? String(l.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()) : l.trimmingCharacters(in: .whitespaces)
            }
            if l.isEmpty && !inFence { blank += 1; if blank > 1 { continue } } else { blank = 0 }
            out.append(inFence && !l.hasPrefix("```") ? l : l.replacingOccurrences(of: "****", with: "").replacingOccurrences(of: "__", with: ""))
        }
        lines = out
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Plain text (for titles, excerpts and token estimates).
    public static func text(_ html: String) -> String {
        convert(html).replacingOccurrences(of: #"[#*_`>\[\]()!-]"#, with: "", options: .regularExpression)
    }

    /// `<title>`, `og:title`, description, canonical URL, language and published date from the head.
    public static func headMetadata(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        if let r = html.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = String(html[r]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            out["title"] = decodeEntities(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let re = try! NSRegularExpression(pattern: #"<meta\s+[^>]*>"#, options: .caseInsensitive)
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range, in: html), let tag = parseTag(String(html[r].dropFirst().dropLast())) else { continue }
            let key = (tag.attrs["property"] ?? tag.attrs["name"] ?? tag.attrs["itemprop"] ?? "").lowercased()
            guard let content = tag.attrs["content"], !content.isEmpty else { continue }
            switch key {
            case "og:title", "twitter:title": out["og:title"] = out["og:title"] ?? content
            case "description", "og:description", "twitter:description": out["description"] = out["description"] ?? content
            case "og:site_name": out["site"] = content
            case "author", "article:author", "dc.creator": out["author"] = out["author"] ?? content
            case "article:published_time", "date", "dc.date", "datepublished", "pubdate": out["published"] = out["published"] ?? content
            case "og:url": out["url"] = content
            case "og:type": out["type"] = content
            default: break
            }
        }
        if let r = html.range(of: #"<link[^>]+rel=["']canonical["'][^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let tag = parseTag(String(html[r].dropFirst().dropLast())), let href = tag.attrs["href"] { out["canonical"] = href }
        if let r = html.range(of: #"<html[^>]*\slang=["']([^"']+)["']"#, options: [.regularExpression, .caseInsensitive]) {
            let s = String(html[r])
            if let q = s.range(of: #"lang=["']([^"']+)"#, options: .regularExpression) { out["lang"] = String(s[q]).replacingOccurrences(of: #"lang=["']"#, with: "", options: .regularExpression) }
        }
        return out
    }
}

/// Picks the main article from a page without a browser: the block-level element with the most
/// text, discounted by link density. Good enough for static pages and the fallback path.
public enum ReaderHeuristics {
    public static func mainContent(_ html: String) -> String {
        var body = html
        if let r = body.range(of: #"<body[^>]*>"#, options: [.regularExpression, .caseInsensitive]) { body = String(body[r.upperBound...]) }
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "aside", "form", "header", "iframe", "template"] {
            body = body.replacingOccurrences(of: #"<\#(tag)[\s\S]*?</\#(tag)\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if let a = body.range(of: #"<article[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let z = body.range(of: "</article>", options: [.caseInsensitive], range: a.upperBound..<body.endIndex) {
            let inner = String(body[a.upperBound..<z.lowerBound])
            if HTMLToMarkdown.text(inner).count > 400 { return inner }
        }
        if let m = body.range(of: #"<main[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let z = body.range(of: "</main>", options: [.caseInsensitive], range: m.upperBound..<body.endIndex) {
            let inner = String(body[m.upperBound..<z.lowerBound])
            if HTMLToMarkdown.text(inner).count > 400 { return inner }
        }
        // Score top-level divs/sections by paragraph text minus link text.
        let re = try! NSRegularExpression(pattern: #"<(div|section)[^>]*>([\s\S]*?)</\1>"#, options: .caseInsensitive)
        var best: (score: Int, html: String)? = nil
        for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let r = Range(m.range(at: 2), in: body) else { continue }
            let chunk = String(body[r])
            let paragraphs = chunk.components(separatedBy: "<p").count - 1
            let text = HTMLToMarkdown.text(chunk)
            let links = chunk.components(separatedBy: "<a ").count - 1
            let score = text.count + paragraphs * 80 - links * 60
            if score > (best?.score ?? 600) { best = (score, chunk) }
        }
        return best?.html ?? body
    }
}
