import Foundation

/// A small, tolerant HTML element tree with the few selectors a list scraper needs: tag, `.class`,
/// `#id`, `[attr]`, `[attr=value]`, descendant (space) and child (`>`) combinators. Scripts, styles and
/// comments are dropped; void elements never take children; unclosed tags close at their parent.
public final class HTMLElement: @unchecked Sendable {
    public let name: String
    public let attributes: [String: String]
    public private(set) var children: [HTMLElement] = []
    public private(set) var textPieces: [(index: Int, text: String)] = []
    public weak var parent: HTMLElement?

    init(name: String, attributes: [String: String], parent: HTMLElement?) {
        self.name = name
        self.attributes = attributes
        self.parent = parent
    }

    func add(_ child: HTMLElement) { children.append(child) }
    func addText(_ t: String) { textPieces.append((children.count, t)) }

    public func attr(_ k: String) -> String? { attributes[k.lowercased()] }
    public var classes: [String] { (attributes["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init) }

    /// Text content, whitespace collapsed.
    public var text: String {
        var out = ""
        func walk(_ e: HTMLElement) {
            var ti = 0
            for (ci, child) in e.children.enumerated() {
                while ti < e.textPieces.count, e.textPieces[ti].index <= ci { out += e.textPieces[ti].text; ti += 1 }
                if ["br", "p", "div", "li", "h1", "h2", "h3", "h4", "tr"].contains(child.name) { out += " " }
                walk(child)
            }
            while ti < e.textPieces.count { out += e.textPieces[ti].text; ti += 1 }
        }
        walk(self)
        return HTMLDocument.decodeEntities(out).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }

    /// `tag.first-class` for grouping look-alike containers.
    public var signature: String {
        if let c = classes.first(where: { !$0.isEmpty && !$0.contains(":") }) { return "\(name).\(c)" }
        return name
    }

    public func select(_ selector: String) -> [HTMLElement] { HTMLSelector.parse(selector).map { $0.matches(in: self) } ?? [] }
    public func first(_ selector: String) -> HTMLElement? { select(selector).first }

    var descendants: [HTMLElement] {
        var out: [HTMLElement] = []
        func walk(_ e: HTMLElement) { for c in e.children { out.append(c); walk(c) } }
        walk(self)
        return out
    }
}

public struct HTMLDocument: Sendable {
    public let root: HTMLElement
    public func select(_ selector: String) -> [HTMLElement] { root.select(selector) }
    public func first(_ selector: String) -> HTMLElement? { root.first(selector) }

    static let void: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    static let skip: Set<String> = ["script", "style", "noscript", "template", "svg"]

    public static func parse(_ html: String) -> HTMLDocument {
        let root = HTMLElement(name: "#root", attributes: [:], parent: nil)
        var current = root
        let s = Array(html.utf8)
        var i = 0
        let n = s.count
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF8.self) }
        while i < n {
            if s[i] == UInt8(ascii: "<") {
                if i + 4 <= n, slice(i, min(n, i + 4)) == "<!--" {
                    if let end = find("-->", from: i + 4) { i = end + 3 } else { i = n }
                    continue
                }
                if i + 1 < n, s[i + 1] == UInt8(ascii: "!") || s[i + 1] == UInt8(ascii: "?") {
                    i = (find(">", from: i) ?? n - 1) + 1
                    continue
                }
                guard let close = find(">", from: i) else { break }
                let inner = slice(i + 1, close)
                i = close + 1
                if inner.hasPrefix("/") {
                    let name = String(inner.dropFirst()).trimmed.lowercased()
                    var e: HTMLElement? = current
                    while let x = e, x.name != name, x !== root { e = x.parent }
                    if let x = e, x !== root { current = x.parent ?? root }
                    continue
                }
                let (name, attrs, selfClosing) = parseTag(inner)
                guard !name.isEmpty else { continue }
                if skip.contains(name) {
                    if let end = findCloseTag(name, from: i) { i = end } else { i = n }
                    continue
                }
                let el = HTMLElement(name: name, attributes: attrs, parent: current)
                current.add(el)
                if !(selfClosing || void.contains(name)) { current = el }
            } else {
                let next = find("<", from: i) ?? n
                let t = slice(i, next)
                if !t.allSatisfy({ $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) { current.addText(t) } else if !t.isEmpty { current.addText(" ") }
                i = next
            }
        }
        func find(_ needle: String, from: Int) -> Int? {
            let nb = Array(needle.utf8)
            var j = from
            while j + nb.count <= n {
                if s[j] == nb[0], Array(s[j..<j + nb.count]) == nb { return j }
                j += 1
            }
            return nil
        }
        func findCloseTag(_ name: String, from: Int) -> Int? {
            var j = from
            while let k = find("</", from: j) {
                if let gt = find(">", from: k), slice(k + 2, gt).trimmed.lowercased() == name { return gt + 1 }
                j = k + 2
            }
            return nil
        }
        return HTMLDocument(root: root)
    }

    static func parseTag(_ inner: String) -> (String, [String: String], Bool) {
        var t = inner.trimmed
        var selfClosing = false
        if t.hasSuffix("/") { selfClosing = true; t = String(t.dropLast()).trimmed }
        let chars = Array(t)
        var i = 0
        var name = ""
        while i < chars.count, !chars[i].isWhitespace { name.append(chars[i]); i += 1 }
        var attrs: [String: String] = [:]
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var key = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=" { key.append(chars[i]); i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let q = chars[i]
                    i += 1
                    while i < chars.count, chars[i] != q { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
            }
            if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
        }
        return (name.lowercased(), attrs, selfClosing)
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&#160;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&#8217;", "’"), ("&#8216;", "‘"), ("&#8220;", "“"), ("&#8221;", "”")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if out.contains("&#") {
            let re = try! NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let code = UInt32(digits, radix: hex ? 16 : 10), let u = Unicode.Scalar(code) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(u)))
                }
            }
        }
        return out
    }
}

struct HTMLSelector {
    struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attrs: [(String, String?)] = []
        var child = false   // combinator before this compound is `>`

        func matches(_ e: HTMLElement) -> Bool {
            if let tag, tag != "*", e.name != tag { return false }
            if let id, e.attr("id") != id { return false }
            if !classes.isEmpty {
                let cs = Set(e.classes)
                for c in classes where !cs.contains(c) { return false }
            }
            for (k, v) in attrs {
                guard let have = e.attr(k) else { return false }
                if let v, have != v { return false }
            }
            return true
        }
    }

    var compounds: [Compound]

    static func parse(_ s: String) -> HTMLSelector? {
        var compounds: [Compound] = []
        var cur = Compound()
        var pendingChild = false
        var token = ""
        var mode: Character = "t"
        func endToken() {
            guard !token.isEmpty else { return }
            switch mode {
            case "#": cur.id = token
            case ".": cur.classes.append(token)
            case "[":
                let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
                cur.attrs.append((parts[0].lowercased(), parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : nil))
            default: cur.tag = token.lowercased()
            }
            token = ""
        }
        func endCompound() {
            endToken()
            guard cur.tag != nil || cur.id != nil || !cur.classes.isEmpty || !cur.attrs.isEmpty else { return }
            cur.child = pendingChild
            compounds.append(cur)
            cur = Compound()
            pendingChild = false
            mode = "t"
        }
        var inAttr = false
        for ch in s {
            if inAttr {
                if ch == "]" { inAttr = false; endToken(); mode = "t" } else { token.append(ch) }
                continue
            }
            switch ch {
            case " ", "\t": endCompound()
            case ">": endCompound(); pendingChild = true
            case "#", ".": endToken(); mode = ch
            case "[": endToken(); mode = "["; inAttr = true
            default: token.append(ch)
            }
        }
        endCompound()
        guard !compounds.isEmpty else { return nil }
        return HTMLSelector(compounds: compounds)
    }

    func matches(in root: HTMLElement) -> [HTMLElement] {
        var candidates = root.descendants
        var out: [HTMLElement] = []
        for e in candidates where matchesChain(e, index: compounds.count - 1) { out.append(e) }
        candidates = []
        return out
    }

    private func matchesChain(_ e: HTMLElement, index: Int) -> Bool {
        let c = compounds[index]
        guard c.matches(e) else { return false }
        if index == 0 { return true }
        if c.child {
            guard let p = e.parent, p.name != "#root" else { return false }
            return matchesChain(p, index: index - 1)
        }
        var p = e.parent
        while let x = p, x.name != "#root" {
            if matchesChain(x, index: index - 1) { return true }
            p = x.parent
        }
        return false
    }
}
