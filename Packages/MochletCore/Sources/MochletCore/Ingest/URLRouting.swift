import Foundation

/// How a URL should be read.
public enum URLRoute: Equatable, Sendable {
    case pdf(URL)
    case arxiv(id: String, abs: URL, pdf: URL)
    case gitHubRepo(owner: String, repo: String)
    case gitHubBlob(raw: URL, path: String)
    case youTube(id: String)
    case page(URL)

    public static func route(_ url: URL) -> URLRoute {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path
        if let id = URLCanonicalizer.arxivID(url.absoluteString) {
            return .arxiv(id: id, abs: URL(string: "https://arxiv.org/abs/\(id)")!, pdf: URL(string: "https://arxiv.org/pdf/\(id)")!)
        }
        if path.lowercased().hasSuffix(".pdf") { return .pdf(url) }
        if host == "github.com" {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                let owner = parts[0], repo = parts[1].replacingOccurrences(of: ".git", with: "")
                if parts.count >= 5, parts[2] == "blob" {
                    let branch = parts[3]
                    let file = parts[4...].joined(separator: "/")
                    if let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(file)") { return .gitHubBlob(raw: raw, path: file) }
                }
                if parts.count == 2 || (parts.count >= 3 && ["tree", "", "#readme"].contains(parts[2])) { return .gitHubRepo(owner: owner, repo: repo) }
            }
        }
        if host == "youtube.com" || host == "m.youtube.com" || host == "youtu.be" || host == "music.youtube.com" {
            if let id = youTubeID(url) { return .youTube(id: id) }
        }
        return .page(url)
    }

    static func youTubeID(_ url: URL) -> String? {
        if url.host?.contains("youtu.be") == true { return url.lastPathComponent.isEmpty ? nil : url.lastPathComponent }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }
}

/// arXiv Atom API → title, authors, summary, published, categories.
public struct ArxivEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var summary: String
    public var published: String?
    public var categories: [String]

    public static func parse(atom: String) -> ArxivEntry? {
        guard let entryRange = atom.range(of: "<entry>"), let end = atom.range(of: "</entry>", range: entryRange.upperBound..<atom.endIndex) else { return nil }
        let entry = String(atom[entryRange.upperBound..<end.lowerBound])
        func tag(_ name: String) -> String? {
            guard let r = entry.range(of: "<\(name)[^>]*>([\\s\\S]*?)</\(name)>", options: .regularExpression) else { return nil }
            var s = String(entry[r])
            s = s.replacingOccurrences(of: "<\(name)[^>]*>", with: "", options: .regularExpression).replacingOccurrences(of: "</\(name)>", with: "")
            return HTMLToMarkdown.decodeEntities(s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var authors: [String] = []
        let re = try! NSRegularExpression(pattern: #"<author>\s*<name>([^<]+)</name>"#)
        for m in re.matches(in: entry, range: NSRange(entry.startIndex..., in: entry)) { if let r = Range(m.range(at: 1), in: entry) { authors.append(String(entry[r]).trimmingCharacters(in: .whitespaces)) } }
        var cats: [String] = []
        let cre = try! NSRegularExpression(pattern: #"<category[^>]*term="([^"]+)""#)
        for m in cre.matches(in: entry, range: NSRange(entry.startIndex..., in: entry)) { if let r = Range(m.range(at: 1), in: entry) { cats.append(String(entry[r])) } }
        guard let title = tag("title") else { return nil }
        let idText = tag("id") ?? ""
        let id = URLCanonicalizer.arxivID(idText) ?? idText
        return ArxivEntry(id: id, title: title, authors: authors, summary: tag("summary") ?? "", published: tag("published"), categories: cats)
    }
}

/// `robots.txt` Disallow rules for one host (user-agent `*` and `Mochlet`).
public struct RobotsRules: Equatable, Sendable {
    public var disallow: [String]
    public var allow: [String]

    public init(disallow: [String] = [], allow: [String] = []) {
        self.disallow = disallow
        self.allow = allow
    }

    public static func parse(_ text: String) -> RobotsRules {
        var rules = RobotsRules()
        var applies = false
        var sawSpecific = false
        var current: [(String, String)] = []
        var generic: [(String, String)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "user-agent" {
                let agent = value.lowercased()
                if agent == "mochlet" { applies = true; sawSpecific = true; current = [] }
                else if agent == "*" { applies = !sawSpecific; if applies { generic = [] } }
                else { applies = false }
                continue
            }
            guard applies, key == "disallow" || key == "allow" else { continue }
            if sawSpecific { current.append((key, value)) } else { generic.append((key, value)) }
        }
        for (k, v) in sawSpecific ? current : generic where !v.isEmpty {
            if k == "disallow" { rules.disallow.append(v) } else { rules.allow.append(v) }
        }
        return rules
    }

    public func allows(path: String) -> Bool {
        func matches(_ rule: String) -> Bool {
            if rule.contains("*") || rule.hasSuffix("$") {
                var pattern = NSRegularExpression.escapedPattern(for: rule).replacingOccurrences(of: "\\*", with: ".*")
                if pattern.hasSuffix("\\$") { pattern = "^" + String(pattern.dropLast(2)) + "$" } else { pattern = "^" + pattern }
                return path.range(of: pattern, options: .regularExpression) != nil
            }
            return path.hasPrefix(rule)
        }
        let longestAllow = allow.filter(matches).map(\.count).max() ?? -1
        let longestDisallow = disallow.filter(matches).map(\.count).max() ?? -1
        return longestAllow >= longestDisallow
    }
}
