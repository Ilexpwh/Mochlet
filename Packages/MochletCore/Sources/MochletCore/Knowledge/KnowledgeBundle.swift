import CryptoKit
import Foundation

/// A page read from disk.
public struct ScannedPage: Sendable, Equatable {
    public var relativePath: String
    public var document: OKFDocument
    public var sha256: String
    public var mtime: Date
    public var size: Int
}

public struct ReindexReport: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var failed: [(path: String, error: String)] = []
    public static func == (l: ReindexReport, r: ReindexReport) -> Bool {
        l.added == r.added && l.updated == r.updated && l.removed == r.removed && l.unchanged == r.unchanged && l.failed.map(\.path) == r.failed.map(\.path)
    }
    public var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.isEmpty ? "\(unchanged) pages, nothing changed" : parts.joined(separator: ", ")
    }
}

/// Our own writes, so the watcher can ignore them (size + mtime of what we wrote).
public final class SelfWriteLedger: @unchecked Sendable {
    private var entries: [String: (size: Int, mtime: Date)] = [:]
    private let lock = NSLock()
    public init() {}
    public func record(path: String, size: Int, mtime: Date) { lock.withLock { entries[path] = (size, mtime) } }
    public func isOwn(path: String, size: Int, mtime: Date) -> Bool {
        lock.withLock { entries[path].map { $0.size == size && abs($0.mtime.timeIntervalSince(mtime)) < 0.5 } ?? false }
    }
}

/// `~/Mochlet/Knowledge` on disk: walking, reading, writing pages and keeping the index in step.
public final class KnowledgeBundle: @unchecked Sendable {
    public let root: URL
    public let ledger = SelfWriteLedger()

    public init(root: URL) { self.root = root }

    public func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    // MARK: Bootstrap

    /// Creates the folders and reserved files that are missing; returns what it created.
    @discardableResult
    public func bootstrap(now: Date = Date()) throws -> [String] {
        let fm = FileManager.default
        var created: [String] = []
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for d in BundleLayout.directories {
            let u = url(d)
            if !fm.fileExists(atPath: u.path) { try fm.createDirectory(at: u, withIntermediateDirectories: true); created.append(d + "/") }
        }
        for f in BundleBootstrap.files(now: now) {
            let u = url(f.relativePath)
            if !fm.fileExists(atPath: u.path) {
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(text: f.contents, to: f.relativePath)
                created.append(f.relativePath)
            } else if f.relativePath == BundleLayout.schemaFile || BundleLayout.agentCopies.contains(f.relativePath) {
                // Keep the schema copies current when ours changed and the user did not edit them.
                if let existing = try? String(contentsOf: u, encoding: .utf8), existing != f.contents, existing.contains("# Knowledge base schema"), !existing.contains("human-edited") {
                    try write(text: f.contents, to: f.relativePath)
                }
            }
        }
        if !fm.fileExists(atPath: url("index.md").path) {
            try write(text: OKFIndexFile.render(directory: "", title: "Knowledge", entries: [], subdirectories: BundleLayout.directories.map { IndexSubdirectory(name: $0) }, isRoot: true, now: now), to: "index.md")
            created.append("index.md")
        }
        return created
    }

    // MARK: Walking

    /// Every page (relative paths), skipping references/, hidden and ignored folders.
    public func pagePaths() -> [String] {
        walk().filter(BundleLayout.isPage)
    }

    /// Files under any `references/` folder.
    public func referencePaths() -> [String] {
        walk().filter(Self.isReference)
    }

    public static func isReference(_ relative: String) -> Bool {
        relative.split(separator: "/").dropLast().contains(Substring(BundleLayout.referencesDir))
    }

    /// Mirrored sources that are plain text, so their full content is searchable (`type: reference`).
    public static let textReferenceExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    public func textReferencePaths() -> [String] {
        referencePaths().filter { Self.textReferenceExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    func walk() -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        let prefix = root.standardizedFileURL.path + "/"
        for case let u as URL in e {
            let name = u.lastPathComponent
            let values = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if BundleLayout.ignoredDirectories.contains(name) || name.hasPrefix(".") { e.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let p = u.standardizedFileURL.path
            guard p.hasPrefix(prefix) else { continue }
            out.append(String(p.dropFirst(prefix.count)))
        }
        return out.sorted()
    }

    public func read(_ relative: String) throws -> String {
        try String(contentsOf: url(relative), encoding: .utf8)
    }

    public func scan(_ relative: String) throws -> ScannedPage {
        let u = url(relative)
        let data = try Data(contentsOf: u)
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        let text = String(decoding: data, as: UTF8.self)
        let doc: OKFDocument
        if Self.isReference(relative) {
            // Raw sources need no frontmatter; a mirrored OKF page keeps its own.
            if let parsed = try? OKFDocument.parse(text) {
                var fm = parsed.frontmatter
                fm.type = "reference"
                doc = OKFDocument(frontmatter: fm, body: parsed.body)
            } else {
                let body = (try? OKFDocument.splitFrontmatter(text).body) ?? text
                let stem = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension
                let title = stem.count > 13 && stem[stem.index(stem.startIndex, offsetBy: 12)] == "-" ? String(stem.dropFirst(13)) : stem
                doc = OKFDocument(frontmatter: OKFFrontmatter(type: "reference", title: title), body: body)
            }
        } else {
            doc = try OKFDocument.parse(text)
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ScannedPage(relativePath: relative, document: doc, sha256: sha, mtime: attrs[.modificationDate] as? Date ?? Date(), size: data.count)
    }

    /// Titles for link resolution, read cheaply (frontmatter title or the first heading).
    public func catalog(paths: [String]? = nil) -> PageCatalog {
        var cat = PageCatalog()
        for p in paths ?? pagePaths() {
            var title: String?
            if let text = try? read(p), let doc = try? OKFDocument.parse(text) { title = doc.frontmatter.title ?? doc.heading }
            cat.add(path: p, title: title)
        }
        return cat
    }

    // MARK: Index

    public func indexedDocument(for page: ScannedPage, catalog: PageCatalog) -> (IndexedDocument, [Chunk]) {
        let doc = page.document
        let fm = doc.frontmatter
        var links: [String] = []
        var unresolved: [String] = []
        for l in WikiLinks.extract(doc.body) {
            if let r = WikiLinks.resolve(l.target, from: page.relativePath, pages: catalog) { links.append(r) } else if !l.isEmbed { unresolved.append(l.target) }
        }
        for t in WikiLinks.markdownTargets(doc.body) {
            let n = WikiLinks.normalizePath(t, from: page.relativePath)
            if catalog.paths.contains(n) { links.append(n) }
        }
        let parts = page.relativePath.split(separator: "/").map(String.init)
        var project = fm.mochlet?["project"]?.string
        if project == nil, parts.count >= 3, parts[0] == "projects" { project = parts[1] }
        let title = fm.title ?? doc.heading ?? ((parts.last ?? "") as NSString).deletingPathExtension
        let sample = String(doc.body.prefix(400))
        let lang = CJK.contains(sample) ? "zh" : "en"
        let d = IndexedDocument(path: page.relativePath, type: fm.type, title: title, description: fm.description ?? doc.firstParagraph.map { OneLine.collapse($0, limit: 200) },
                                resource: fm.resource, tags: fm.tags, status: fm.status, staleAfter: fm.staleAfter, generatedBy: fm.generated?.by, generatedAt: fm.generated?.at,
                                project: project, lang: lang, sha256: page.sha256, mtime: page.mtime, size: page.size, frontmatterYAML: YAMLLite.emit(fm.yaml()),
                                sourceCount: fm.sources.count, isHumanOwned: fm.isHumanOwned, links: Array(Set(links)).sorted(), unresolvedLinks: Array(Set(unresolved)).sorted())
        let bodyLine = Self.isReference(page.relativePath) && fm.title != nil && (try? OKFDocument.parse(try read(page.relativePath))) == nil
            ? 1
            : (try? OKFDocument.splitFrontmatter(try read(page.relativePath)).yaml.split(separator: "\n").count).map { $0 + 3 } ?? 1
        var chunks = Chunker().chunk(doc.body, firstLine: bodyLine)
        if chunks.isEmpty {
            chunks = [Chunk(ordinal: 0, headingPath: "", text: title + (d.description.map { ". " + $0 } ?? ""), tokenCount: 4, lineStart: 1, lineEnd: 1)]
        }
        return (d, chunks)
    }

    /// Brings the index in step with the folder: new/changed pages are re-chunked, deleted pages removed.
    @discardableResult
    public func reindex(into index: KnowledgeIndex, force: Bool = false, only: Set<String>? = nil) throws -> ReindexReport {
        var report = ReindexReport()
        let pages = pagePaths()
        let paths = pages + textReferencePaths()
        let known = try index.fingerprints()
        let catalog = catalog(paths: pages)
        let pathSet = Set(paths)
        for p in paths where only == nil || only!.contains(p) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url(p).path)
                let mtime = attrs[.modificationDate] as? Date ?? Date()
                if !force, let k = known[p], abs(k.mtime.timeIntervalSince(mtime)) < 0.001 { report.unchanged += 1; continue }
                let page = try scan(p)
                if !force, let k = known[p], k.sha256 == page.sha256 { report.unchanged += 1; continue }
                let (d, chunks) = indexedDocument(for: page, catalog: catalog)
                try index.upsert(d, chunks: chunks)
                if known[p] == nil { report.added += 1 } else { report.updated += 1 }
            } catch {
                report.failed.append((p, "\(error)"))
            }
        }
        var removedPaths: Set<String> = []
        for p in known.keys where !pathSet.contains(p) && (only == nil || only!.contains(p)) {
            try index.remove(path: p)
            report.removed += 1
            removedPaths.insert(p)
        }
        // Links are resolved when the linking page is indexed; a page added or removed later changes
        // the answer for pages that did not change themselves, so those are indexed again.
        if report.added > 0 || !removedPaths.isEmpty {
            var again: Set<String> = []
            for l in try index.allLinks() {
                if again.contains(l.from) || !pathSet.contains(l.from) { continue }
                if !l.resolved, WikiLinks.resolve(l.to, from: l.from, pages: catalog) != nil { again.insert(l.from) }
                if l.resolved, removedPaths.contains(l.to) { again.insert(l.from) }
            }
            for p in again {
                do {
                    let page = try scan(p)
                    let (d, chunks) = indexedDocument(for: page, catalog: catalog)
                    try index.upsert(d, chunks: chunks)
                    report.updated += 1
                } catch {
                    report.failed.append((p, "\(error)"))
                }
            }
        }
        return report
    }

    // MARK: Writing

    public func write(text: String, to relative: String) throws {
        let u = url(relative)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(text.utf8)
        try data.write(to: u, options: .atomic)
        let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
        ledger.record(path: relative, size: data.count, mtime: attrs[.modificationDate] as? Date ?? Date())
    }

    public func write(_ doc: OKFDocument, to relative: String) throws {
        try write(text: doc.serialize(), to: relative)
    }

    public func isOwnWrite(_ relative: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url(relative).path), let size = attrs[.size] as? Int, let m = attrs[.modificationDate] as? Date else { return false }
        return ledger.isOwn(path: relative, size: size, mtime: m)
    }

    /// A unique slug for a new page in `directory`.
    public func uniqueSlug(_ title: String, in directory: String) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: url(directory).path)) ?? []
        let taken = Set(existing.filter { $0.hasSuffix(".md") }.map { ($0 as NSString).deletingPathExtension })
        return Slug.unique(Slug.make(title), taken: taken)
    }

    /// Copies a source into `<directory>/references/<sha12>-<name>`; returns the relative path and sha256.
    public func mirror(fileAt source: URL, into directory: String) throws -> (relativePath: String, sha256: String) {
        let data = try Data(contentsOf: source)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = String(sha.prefix(12)) + "-" + Slug.make((source.lastPathComponent as NSString).deletingPathExtension, maxLength: 48) + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension.lowercased())
        let rel = "\(directory)/\(BundleLayout.referencesDir)/\(name)"
        let dest = url(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .atomic) }
        return (rel, sha)
    }

    public func mirror(text: String, name: String, into directory: String) throws -> (relativePath: String, sha256: String) {
        let data = Data(text.utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = (name as NSString).pathExtension
        let base = Slug.make((name as NSString).deletingPathExtension, maxLength: 48)
        let rel = "\(directory)/\(BundleLayout.referencesDir)/\(sha.prefix(12))-\(base)\(ext.isEmpty ? ".md" : "." + ext)"
        let dest = url(rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: dest.path) { try data.write(to: dest, options: .atomic) }
        return (rel, sha)
    }

    // MARK: Reserved files

    /// Regenerates every `index.md`, `.abstract.md` and `.overview.md` from the index database.
    public func regenerateIndexes(from index: KnowledgeIndex, now: Date = Date()) throws {
        let docs = try index.documents()
        var byDir: [String: [IndexedDocument]] = [:]
        for d in docs {
            let dir = (d.path as NSString).deletingLastPathComponent
            byDir[dir, default: []].append(d)
        }
        var dirs = Set(byDir.keys)
        dirs.insert("")
        for d in BundleLayout.directories { dirs.insert(d) }
        // Every ancestor of a directory with pages also needs an index.
        for d in Array(dirs) {
            var parts = d.split(separator: "/").map(String.init)
            while !parts.isEmpty { parts.removeLast(); dirs.insert(parts.joined(separator: "/")) }
        }
        func pageCount(under dir: String) -> Int {
            docs.filter { dir.isEmpty ? true : $0.path.hasPrefix(dir + "/") }.count
        }
        for dir in dirs.sorted(by: { $0.count > $1.count }) {
            let entries = (byDir[dir] ?? []).map { IndexEntry(path: ($0.path as NSString).lastPathComponent, title: $0.title, description: $0.description, type: $0.type, sourceCount: $0.sourceCount, status: $0.status) }
            let children = dirs.filter { child in
                let parent = (child as NSString).deletingLastPathComponent
                return !child.isEmpty && parent == dir && child != dir
            }
            let subs = children.map { child -> IndexSubdirectory in
                let name = (child as NSString).lastPathComponent
                let abstract = (try? read(child + "/.abstract.md")).flatMap { try? OKFDocument.splitFrontmatter($0).body.trimmingCharacters(in: .whitespacesAndNewlines) }
                return IndexSubdirectory(name: name, abstract: abstract, pageCount: pageCount(under: child))
            }
            let title = dir.isEmpty ? "Knowledge" : (dir as NSString).lastPathComponent.prefix(1).uppercased() + (dir as NSString).lastPathComponent.dropFirst()
            let text = OKFIndexFile.render(directory: dir, title: title, entries: entries, subdirectories: subs, isRoot: dir.isEmpty, now: now)
            let rel = dir.isEmpty ? "index.md" : dir + "/index.md"
            if (try? read(rel)) != text { try write(text: text, to: rel) }
            if !dir.isEmpty {
                let (abstract, overview) = sidecars(dir: dir, entries: entries, subs: subs, now: now)
                let ar = dir + "/.abstract.md", ov = dir + "/.overview.md"
                if (try? read(ar)) != abstract { try write(text: abstract, to: ar) }
                if (try? read(ov)) != overview { try write(text: overview, to: ov) }
            }
        }
    }

    func sidecars(dir: String, entries: [IndexEntry], subs: [IndexSubdirectory], now: Date) -> (String, String) {
        let name = (dir as NSString).lastPathComponent
        let types = Dictionary(grouping: entries, by: \.type).map { "\($0.value.count) \(BundleLayout.sectionTitle(forType: $0.key).lowercased())" }.sorted().joined(separator: ", ")
        var abstract = "\(name)/: " + (types.isEmpty ? "no pages yet" : types)
        let sample = Sidecar.sample(entries.map(\.title), limit: 5)
        if !sample.isEmpty { abstract += ". E.g. " + sample.joined(separator: "; ") }
        var overview = "# \(name)/\n\n" + (types.isEmpty ? "No pages yet.\n" : types + ".\n\n")
        for e in Sidecar.sample(entries.map { "\($0.title): \($0.description ?? "")" }, limit: 32) { overview += "- " + OneLine.collapse(e, limit: 160) + "\n" }
        for s in subs { overview += "- \(s.name)/ (\(s.pageCount) pages)\n" }
        return Sidecar.render(directory: dir, abstract: abstract, overview: overview, total: entries.count + subs.count, sampled: min(32, entries.count) + subs.count, now: now)
    }

    public func appendLog(kind: String, text: String, now: Date = Date()) throws {
        let existing = try? read("log.md")
        try write(text: OKFLogFile.append(existing, kind: kind, text: text, now: now), to: "log.md")
    }

    // MARK: Lint input

    public func lintPages(from index: KnowledgeIndex) throws -> [LintPage] {
        let docs = try index.documents()
        let links = try index.allLinks()
        var resolved: [String: [String]] = [:]
        var unresolved: [String: [String]] = [:]
        for l in links { if l.resolved { resolved[l.from, default: []].append(l.to) } else { unresolved[l.from, default: []].append(l.to) } }
        return docs.map { d in
            var mentions: [String] = []
            var integrated = true
            if d.type == "report" {
                if let text = try? read(d.path), let doc = try? OKFDocument.parse(text) {
                    mentions = KnowledgeLinter.entityMentions(in: doc.body)
                    integrated = doc.frontmatter.mochlet?["integrated"]?.bool ?? false
                }
            }
            return LintPage(path: d.path, title: d.title, type: d.type, links: resolved[d.path] ?? [], unresolvedLinks: unresolved[d.path] ?? [], entityMentions: mentions,
                            sourceIDs: [], integrated: integrated, isHumanOwned: d.isHumanOwned, staleAfter: d.staleAfter, status: d.status)
        }
    }

    /// Source keys of references that have a report (`mochlet.sha256` or `mochlet.reference`).
    public func reportedReferences(from index: KnowledgeIndex) throws -> Set<String> {
        var out: Set<String> = []
        for d in try index.documents(types: ["report"]) {
            if let n = try? YAMLLite.parse(d.frontmatterYAML), let r = n["mochlet"]?["reference"]?.string { out.insert(r) }
        }
        return out
    }

    /// Plain-text summary of the root index for prompts (first ≈ 1500 chars of the body).
    public func indexSummary() -> String? {
        guard let text = try? read("index.md"), let doc = try? OKFDocument.parse(text) else { return nil }
        let body = doc.body.replacingOccurrences(of: OKFIndexFile.marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(body.prefix(1500))
    }
}
