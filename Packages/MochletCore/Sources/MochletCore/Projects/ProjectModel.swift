import Foundation
import CryptoKit

/// A registered project: a folder (or several) the user works in, with the agent sessions it had.
public struct Project: Codable, Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var aliases: [String]
    public var description: String
    public var paths: [String]
    public var repo: String?
    /// `AgentKind.id` used by "Work on…" when none is given.
    public var defaultAgent: String?
    public var tags: [String]
    public var createdAt: Date
    public var archived: Bool
    /// agent id → last session id (for "Resume <project>").
    public var lastSessions: [String: String]
    /// Background ("headless") agent runs are only allowed in trusted folders: folders the user
    /// picked from disk are trusted; clones are not until the user says so (a cloned repo can carry
    /// project-level agent hooks that would run unattended).
    public var trusted: Bool

    public var id: String { slug }
    public var primaryPath: String? { paths.first }

    public init(slug: String, name: String, aliases: [String] = [], description: String = "", paths: [String], repo: String? = nil,
                defaultAgent: String? = nil, tags: [String] = [], createdAt: Date = Date(), archived: Bool = false, lastSessions: [String: String] = [:],
                trusted: Bool = true) {
        self.slug = slug
        self.name = name
        self.aliases = aliases
        self.description = description
        self.paths = paths
        self.repo = repo
        self.defaultAgent = defaultAgent
        self.tags = tags
        self.createdAt = createdAt
        self.archived = archived
        self.lastSessions = lastSessions
        self.trusted = trusted
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, aliases, description, paths, repo, tags, archived, trusted
        case defaultAgent = "default_agent"
        case createdAt = "created_at"
        case lastSessions = "last_sessions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        defaultAgent = try c.decodeIfPresent(String.self, forKey: .defaultAgent)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        lastSessions = try c.decodeIfPresent([String: String].self, forKey: .lastSessions) ?? [:]
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted) ?? true
    }
}

/// `~/Mochlet/projects.json`.
public struct ProjectsFile: Codable, Sendable, Equatable {
    public var version: Int
    public var defaultProject: String
    public var projects: [Project]

    public init(version: Int = 1, defaultProject: String = "inbox", projects: [Project] = []) {
        self.version = version
        self.defaultProject = defaultProject
        self.projects = projects
    }

    enum CodingKeys: String, CodingKey {
        case version, projects
        case defaultProject = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        defaultProject = try c.decodeIfPresent(String.self, forKey: .defaultProject) ?? "inbox"
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
    }

    public static func decode(_ data: Data) throws -> ProjectsFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISODate.parse(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return try d.decode(ProjectsFile.self, from: data)
    }

    public func encode() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.string(date))
        }
        var data = try e.encode(self)
        data.append(0x0A)
        return data
    }

    public func project(slug: String) -> Project? { projects.first { $0.slug == slug } }

    /// Non-archived projects, by name.
    public var active: [Project] { projects.filter { !$0.archived }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
}

enum ISODate {
    static func parse(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
    static func string(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle()) }
}

/// ASCII slugs for file and project names (CJK → pinyin through the Latin transform).
public enum Slug {
    public static func make(_ title: String, maxLength: Int = 60) -> String {
        var s = title.precomposedStringWithCompatibilityMapping
        if let latin = s.applyingTransform(.toLatin, reverse: false) { s = latin }
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var lastDash = true
        for ch in s.unicodeScalars {
            if (ch.value >= 48 && ch.value <= 57) || (ch.value >= 97 && ch.value <= 122) {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > maxLength {
            // Cut at a word boundary when one falls in the back half, so slugs do not end mid-word.
            let head = String(out.prefix(maxLength + 1))
            if let dash = head.lastIndex(of: "-"), head.distance(from: head.startIndex, to: dash) >= maxLength / 2 {
                out = String(head[..<dash])
            } else {
                out = String(out.prefix(maxLength))
            }
            while out.hasSuffix("-") { out.removeLast() }
        }
        if out.isEmpty {
            let digest = SHA256.hash(data: Data(title.utf8)).compactMap { String(format: "%02x", $0) }.joined()
            return "untitled-" + String(digest.prefix(6))
        }
        return out
    }

    /// `base`, else `base-2`, `base-3`… not in `taken`.
    public static func unique(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// Which project a session belongs to: the longest registered path containing its cwd, else
/// the git root / cwd folder as a shadow project.
public enum ProjectResolver {
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        if p.hasPrefix("/private/var/") { p = String(p.dropFirst("/private".count)) }
        if p.hasPrefix("/private/tmp/") { p = String(p.dropFirst("/private".count)) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func resolve(cwd: String, sessionRoot: String?, projects: [Project], fallbackName: String? = nil) -> ProjectRef {
        let dir = normalize(cwd)
        var best: (Project, String)?
        for p in projects where !p.archived {
            for raw in p.paths {
                let path = normalize(raw)
                guard dir == path || dir.hasPrefix(path + "/") else { continue }
                if best == nil || path.count > best!.1.count { best = (p, path) }
            }
        }
        if let (p, path) = best { return ProjectRef(name: p.name, path: path, isRegistered: true) }
        let root = sessionRoot.map(normalize) ?? dir
        let name = fallbackName ?? (root as NSString).lastPathComponent
        return ProjectRef(name: name.isEmpty ? "project" : name, path: root)
    }

    /// The registered project containing a path, if any.
    public static func project(containing path: String, in projects: [Project]) -> Project? {
        let dir = normalize(path)
        var best: (Project, Int)?
        for p in projects where !p.archived {
            for raw in p.paths {
                let root = normalize(raw)
                guard dir == root || dir.hasPrefix(root + "/") else { continue }
                if best == nil || root.count > best!.1 { best = (p, root.count) }
            }
        }
        return best?.0
    }
}

/// Finds a project by what the user typed or said: exact name/alias/slug, unique prefix, then
/// a small edit distance.
public enum ProjectMatcher {
    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func match(_ query: String, in projects: [Project]) -> Project? {
        let q = norm(query)
        guard !q.isEmpty else { return nil }
        let live = projects.filter { !$0.archived }
        func names(_ p: Project) -> [String] { ([p.name, p.slug] + p.aliases).map(norm) }
        if let exact = live.first(where: { names($0).contains(q) }) { return exact }
        if let bySlug = live.first(where: { $0.slug == Slug.make(q) }) { return bySlug }
        let prefixed = live.filter { names($0).contains { $0.hasPrefix(q) } }
        if prefixed.count == 1 { return prefixed[0] }
        if q.count >= 3 {
            var best: (Project, Int)?
            var tie = false
            for p in live {
                let d = names(p).map { Levenshtein.distance($0, q) }.min() ?? Int.max
                guard d <= 2 else { continue }
                if best == nil || d < best!.1 { best = (p, d); tie = false } else if d == best!.1 { tie = true }
            }
            if let best, !tie { return best.0 }
        }
        return nil
    }
}

public enum Levenshtein {
    public static func distance(_ a: String, _ b: String) -> Int {
        let s = Array(a.unicodeScalars), t = Array(b.unicodeScalars)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }
}
