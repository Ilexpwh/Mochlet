import Foundation

/// What the user asked the slime to do with projects, typed or spoken (English and Chinese).
public enum ProjectIntent: Equatable, Sendable {
    case makeProject(path: String, name: String?)
    case clone(url: String, name: String?)
    case workOn(project: String, task: String, agent: String?)
    case resume(project: String, agent: String?)
    case open(project: String, terminal: String?)
    case listProjects
}

public enum ProjectIntentParser {
    private static let agents = "claude|codex|gemini"
    private static let terminals = "terminal|iterm2?|ghostty|warp|kitty|wezterm|alacritty|cursor|vs ?code|code"

    private struct Rule: Sendable {
        let pattern: String
        let build: @Sendable ([String?]) -> ProjectIntent?
    }

    private static let rules: [Rule] = [
        Rule(pattern: #"^(?:list|show)\s+(?:my\s+)?projects\??$"#) { _ in .listProjects },
        Rule(pattern: #"^(?:项目列表|列出项目|我的项目)$"#) { _ in .listProjects },
        Rule(pattern: #"^(?:make|register|turn)\s+(.+?)\s+(?:into\s+)?(?:a\s+|as\s+a\s+)?project(?:\s+(?:called|named)\s+(.+?))?\.?$"#) { g in
            .makeProject(path: cleanPath(g[1] ?? ""), name: cleanName(g[2])) },
        Rule(pattern: #"^add\s+project\s+(.+?)(?:\s+(?:called|named|as)\s+(.+?))?\.?$"#) { g in
            .makeProject(path: cleanPath(g[1] ?? ""), name: cleanName(g[2])) },
        Rule(pattern: #"^(?:把|将)\s*(.+?)\s*(?:设为|设置为|加为|添加为|作为)\s*项目(?:\s*[,，]?\s*(?:叫|名为|命名为)\s*(.+?))?[。.]?$"#) { g in
            .makeProject(path: cleanPath(g[1] ?? ""), name: cleanName(g[2])) },
        Rule(pattern: #"^(?:添加|新建)项目\s*(.+?)(?:\s*(?:叫|名为)\s*(.+?))?[。.]?$"#) { g in
            .makeProject(path: cleanPath(g[1] ?? ""), name: cleanName(g[2])) },
        Rule(pattern: #"^(?:git\s+)?clone\s+(\S+)(?:\s+(?:as|called|named|into)\s+(.+?))?\.?$"#) { g in
            .clone(url: g[1] ?? "", name: cleanName(g[2])) },
        Rule(pattern: #"^克隆\s*(\S+)(?:\s*(?:为|叫|到)\s*(.+?))?[。.]?$"#) { g in
            .clone(url: g[1] ?? "", name: cleanName(g[2])) },
        Rule(pattern: #"^(?:work\s+on|continue\s+on|let'?s\s+work\s+on|start\s+on)\s*([^:：]+?)\s*[:：]\s*(.+?)(?:\s+(?:with|using|in)\s+(claude|codex|gemini))?\.?$"#) { g in
            .workOn(project: trim(g[1]), task: trim(g[2]), agent: g[3]?.lowercased()) },
        Rule(pattern: #"^(?:在|处理|开发|继续做)\s*([^:：]+?)\s*(?:上|里|中)?\s*(?:工作|做|开发|处理)?\s*[:：]\s*(.+?)(?:\s*[,，]?\s*用\s*(claude|codex|gemini))?[。.]?$"#) { g in
            .workOn(project: trim(g[1]), task: trim(g[2]), agent: g[3]?.lowercased()) },
        Rule(pattern: #"^(?:resume|continue)\s+(.+?)(?:\s+(?:with|using|in)\s+(claude|codex|gemini))?\.?$"#) { g in
            .resume(project: trim(g[1]), agent: g[2]?.lowercased()) },
        Rule(pattern: #"^继续\s*(.+?)(?:\s*[,，]?\s*用\s*(claude|codex|gemini))?[。.]?$"#) { g in
            .resume(project: trim(g[1]), agent: g[2]?.lowercased()) },
        Rule(pattern: #"^open\s+(.+?)(?:\s+in\s+(terminal|iterm2?|ghostty|warp|kitty|wezterm|alacritty|cursor|vs ?code|code))?\.?$"#) { g in
            .open(project: trim(g[1]), terminal: g[2].map(cleanTerminal)) },
        Rule(pattern: #"^(?:打开|用终端打开)\s*(.+?)(?:\s*(?:用|在)\s*(terminal|iterm2?|ghostty|warp|kitty|wezterm|alacritty|cursor|vs ?code|code))?[。.]?$"#) { g in
            .open(project: trim(g[1]), terminal: g[2].map(cleanTerminal)) },
    ]

    public static func parse(_ text: String) -> ProjectIntent? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 2000 else { return nil }
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: t, range: full) else { continue }
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            while groups.count < 4 { groups.append(nil) }
            if let intent = rule.build(groups) { return intent }
        }
        return nil
    }

    private static func trim(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces) }

    static func cleanPath(_ s: String) -> String {
        (unquote(s) as NSString).expandingTildeInPath
    }

    static func cleanName(_ s: String?) -> String? {
        guard let s else { return nil }
        let n = unquote(s)
        return n.isEmpty ? nil : n
    }

    private static func unquote(_ s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespaces)
        let pairs: [(String, String)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("`", "`")]
        for (a, b) in pairs where p.hasPrefix(a) && p.hasSuffix(b) && p.count >= 2 { p = String(p.dropFirst().dropLast()) }
        return p.trimmingCharacters(in: .whitespaces)
    }

    static func cleanTerminal(_ s: String) -> String {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        switch t {
        case "iterm", "iterm2": return "iterm"
        case "vscode", "code": return "vscode"
        default: return t
        }
    }
}
