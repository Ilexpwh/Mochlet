import Foundation
import MochletCore
import MochletServices

/// Everything that touches the bundle folder and the SQLite index runs here, off the main thread,
/// one job at a time. Results are plain values; the controller keeps the UI state.
actor KnowledgeEngine {
    struct Counts: Sendable, Equatable {
        var pages = 0
        var chunks = 0
        var references = 0
        var embedded = 0
    }

    struct Filed: Sendable, Equatable {
        var title: String
        var path: String
        var existing: Bool
        var note: String?
    }

    struct LintResult: Sendable {
        var findings: [LintFinding]
        var path: String
        var pages: Int
    }

    struct TreeNode: Sendable {
        var path: String
        var pages: Int
        var children: [TreeNode]
    }

    let bundle: KnowledgeBundle
    let indexPath: String
    private var index: KnowledgeIndex?
    private var vectors: VectorStore?
    private let embedder = AppleContextualEmbedding()
    var embeddingsEnabled = true

    init(root: URL, indexPath: String) {
        bundle = KnowledgeBundle(root: root)
        self.indexPath = indexPath
    }

    var root: URL { bundle.root }

    func setEmbeddings(_ on: Bool) { embeddingsEnabled = on }

    private func open() throws -> KnowledgeIndex {
        if let index { return index }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: indexPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let i = try KnowledgeIndex(path: indexPath)
        index = i
        vectors = try? i.loadVectors(model: embedder.id)
        return i
    }

    func counts() -> Counts {
        guard let i = try? open() else { return Counts() }
        return Counts(pages: i.documentCount, chunks: i.chunkCount, references: i.referenceCount, embedded: vectors?.count ?? 0)
    }

    func bootstrap() throws -> [String] { try bundle.bootstrap() }

    /// Incremental by default (mtime + sha); `force` re-chunks everything.
    @discardableResult
    func reindex(force: Bool = false, only: Set<String>? = nil) throws -> ReindexReport {
        let i = try open()
        let r = try bundle.reindex(into: i, force: force, only: only)
        if force || r.added + r.updated + r.removed > 0 { try bundle.regenerateIndexes(from: i) }
        return r
    }

    func regenerateIndexes() throws { try bundle.regenerateIndexes(from: try open()) }

    // MARK: Retrieval

    func find(_ query: String, k: Int = 8, filters: FindFilters = FindFilters()) async throws -> [KnowledgeHit] {
        let i = try open()
        var qv: [Float]?
        if embeddingsEnabled, let vectors, vectors.count > 0, AppleContextualEmbedding.assetsAvailable(for: query) {
            qv = try? await embedder.embed([query]).first
        }
        return try i.find(query, k: k, filters: filters, vectors: qv == nil ? nil : vectors, queryVector: qv)
    }

    /// Lexical variants of the question, merged: the passages an answer is built from.
    func hits(for question: String, k: Int = 8) async throws -> [KnowledgeHit] {
        var lists: [[KnowledgeHit]] = []
        for v in QueryPlanner.lexicalVariants(question) {
            let l = try await find(v, k: k)
            if !l.isEmpty { lists.append(l) }
        }
        return QueryPlanner.merge(lists, k: k)
    }

    func grep(_ needle: String, limit: Int = 50, pathPrefix: String? = nil) throws -> [KnowledgeHit] {
        try open().grep(needle, limit: limit, pathPrefix: pathPrefix)
    }

    func indexSummary() -> String? { bundle.indexSummary() }

    func read(_ relative: String) throws -> String { try bundle.read(relative) }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: bundle.url(relative).path) }

    func pagePaths() -> [String] { bundle.pagePaths() }

    func isOwnWrite(_ relative: String) -> Bool { bundle.isOwnWrite(relative) }

    func documents(pathPrefix: String? = nil, types: [String]? = nil) throws -> [IndexedDocument] {
        try open().documents(types: types, pathPrefix: pathPrefix)
    }

    func tree(depth: Int) -> TreeNode {
        let pages = bundle.pagePaths()
        func node(_ dir: String, level: Int) -> TreeNode {
            let prefix = dir.isEmpty ? "" : dir + "/"
            let under = pages.filter { $0.hasPrefix(prefix) }
            var childDirs: Set<String> = []
            for p in under {
                let rest = p.dropFirst(prefix.count)
                if let slash = rest.firstIndex(of: "/") { childDirs.insert(prefix + rest[..<slash]) }
            }
            let children = level < depth ? childDirs.sorted().map { node($0, level: level + 1) } : []
            return TreeNode(path: dir, pages: under.count, children: children)
        }
        return node("", level: 0)
    }

    // MARK: Filing

    private func ensureDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: bundle.url(relative), withIntermediateDirectories: true)
    }

    private func directory(forProject project: String?) -> String {
        project.map { "projects/\($0)" } ?? BundleLayout.inbox
    }

    /// Files a text or Markdown file as a report; other kinds are mirrored with a stub until the
    /// ingestion milestone adds the extractors, so nothing dropped on the slime is lost.
    func addFile(_ url: URL, project: String?, from: String, force: Bool = false) throws -> Filed {
        let i = try open()
        let dir = directory(forProject: project)
        try ensureDirectory(dir)
        let (refPath, sha) = try bundle.mirror(fileAt: url, into: dir)
        let key = ReportWriter.sourceKey(sha256: sha)
        if !force, let rec = try i.ingestRecord(sourceKey: key), rec.status == "done", let p = rec.path, exists(p) {
            let title = (try? i.document(path: p))?.title ?? url.lastPathComponent
            return Filed(title: title, path: p, existing: true, note: "Already chewed")
        }
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        var draft: ReportDraft
        var extractors: [String] = []
        var words = 0
        var note: String?
        if KnowledgeBundle.textReferenceExtensions.contains(ext) || ext.isEmpty, size <= 4_000_000, let text = try? String(contentsOf: url, encoding: .utf8), !text.contains("\0") {
            let parsed = try? OKFDocument.parse(text)
            let body = parsed?.body ?? ((try? OKFDocument.splitFrontmatter(text).body) ?? text)
            let title = parsed?.frontmatter.title ?? OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: body).heading ?? (url.lastPathComponent as NSString).deletingPathExtension
            draft = ReportDraft.fromText(title: title, markdown: body)
            extractors = ["text"]
            words = body.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        } else {
            let title = (url.lastPathComponent as NSString).deletingPathExtension
            let kind = Self.kind(forExtension: ext)
            draft = ReportDraft(title: title, oneLiner: "\(kind) mirrored into the knowledge base, waiting for extraction.",
                                summary: "Mochlet kept a copy of this \(kind.lowercased()) under references/. Reading \(ext.isEmpty ? "this kind of file" : ".\(ext) files") (text, OCR, transcription) arrives with the ingestion milestone; until then open the mirrored copy from the Source section.")
            draft.contentKind = kind.lowercased()
            draft.language = "en"
            note = "Mirrored; extraction for .\(ext) comes with the ingestion milestone."
        }
        if let project { draft.suggestedProject = project }
        let prov = ReportProvenance(sourceKey: key, resource: "file://" + url.path, referencePath: refPath, ingestedFrom: from, extractors: extractors,
                                    words: words, project: project, sha256: sha)
        return try file(draft, provenance: prov, in: dir, index: i, note: note)
    }

    func addText(_ text: String, title: String?, project: String?, from: String) throws -> Filed {
        let i = try open()
        let dir = directory(forProject: project)
        try ensureDirectory(dir)
        let parsed = try? OKFDocument.parse(text)
        let body = parsed?.body ?? text
        let heading = OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: body).heading
        let t = title ?? parsed?.frontmatter.title ?? heading ?? OneLine.collapse(body.split(separator: "\n").first.map(String.init) ?? "Note", limit: 80)
        let (refPath, sha) = try bundle.mirror(text: text, name: Slug.make(t) + ".md", into: dir)
        let key = ReportWriter.sourceKey(sha256: sha)
        if let rec = try i.ingestRecord(sourceKey: key), rec.status == "done", let p = rec.path, exists(p) {
            return Filed(title: t, path: p, existing: true, note: "Already chewed")
        }
        var draft = ReportDraft.fromText(title: t, markdown: body)
        if let project { draft.suggestedProject = project }
        let prov = ReportProvenance(sourceKey: key, referencePath: refPath, ingestedFrom: from, extractors: ["text"],
                                    words: body.split(whereSeparator: { $0 == " " || $0 == "\n" }).count, project: project, sha256: sha)
        return try file(draft, provenance: prov, in: dir, index: i, note: nil)
    }

    /// A link: filed as a draft report now (so it is searchable and listed), read in full by the web reader of the ingestion milestone.
    func addLink(_ url: URL, project: String?, from: String) throws -> Filed {
        let i = try open()
        let dir = directory(forProject: project)
        try ensureDirectory(dir)
        let canonical = URLCanonicalizer.canonical(url.absoluteString)
        let key = ReportWriter.sourceKey(url: url.absoluteString)
        if let rec = try i.ingestRecord(sourceKey: key), rec.status == "done", let p = rec.path, exists(p) {
            let title = (try? i.document(path: p))?.title ?? canonical
            return Filed(title: title, path: p, existing: true, note: "Already chewed")
        }
        let host = url.host ?? "link"
        let last = url.lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let title = last.count > 3 && last != "/" ? "\(host): \(last)" : host
        var draft = ReportDraft(title: title, oneLiner: "Link saved from a drop: \(canonical)", summary: "Saved \(canonical). The web reader (ingestion milestone) fetches the page, mirrors a readable copy and rewrites this report; until then the link itself is what is known.")
        draft.contentKind = "link"
        draft.tags = ["link", host]
        if let project { draft.suggestedProject = project }
        let prov = ReportProvenance(sourceKey: key, resource: canonical, ingestedFrom: from, project: project)
        return try file(draft, provenance: prov, in: dir, index: i, note: "Saved the link; full reading arrives with the ingestion milestone.")
    }

    private func file(_ draft: ReportDraft, provenance: ReportProvenance, in dir: String, index i: KnowledgeIndex, note: String?) throws -> Filed {
        let page = ReportWriter.document(draft, provenance: provenance)
        let slug = bundle.uniqueSlug(draft.title, in: dir)
        let rel = "\(dir)/\(slug).md"
        try bundle.write(page, to: rel)
        try i.recordIngest(sourceKey: provenance.sourceKey, path: rel, status: "done")
        try bundle.appendLog(kind: "ingest", text: "\(draft.title) → \(rel)")
        var touched: Set<String> = [rel]
        if let r = provenance.referencePath { touched.insert(r) }
        try bundle.reindex(into: i, only: touched)
        try bundle.regenerateIndexes(from: i)
        return Filed(title: draft.title, path: rel, existing: false, note: note)
    }

    /// "File this answer": a synthesis page plus backlinks from the cited pages Mochlet owns.
    func fileAnswer(question: String, answer: String, citations: [Citation]) throws -> String {
        let i = try open()
        try ensureDirectory(BundleLayout.syntheses)
        let existing = Set(bundle.pagePaths().filter { $0.hasPrefix(BundleLayout.syntheses + "/") }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension })
        let (slug, doc) = SynthesisWriter.page(question: question, answer: answer, citations: citations, existingSlugs: existing)
        let rel = "\(BundleLayout.syntheses)/\(slug).md"
        try bundle.write(doc, to: rel)
        var touched: Set<String> = [rel]
        let line = SynthesisWriter.backlinkLine(synthesisSlug: slug, title: doc.frontmatter.title ?? slug)
        for path in Set(citations.map(\.path)) where !KnowledgeBundle.isReference(path) {
            guard let d = try? i.document(path: path), !d.isHumanOwned, let text = try? bundle.read(path), let page = try? OKFDocument.parse(text) else { continue }
            let body = SynthesisWriter.addBacklink(to: page.body, line: line)
            if body != page.body {
                try bundle.write(OKFDocument(frontmatter: page.frontmatter, body: body), to: path)
                touched.insert(path)
            }
        }
        try bundle.appendLog(kind: "query", text: "\(OneLine.collapse(question, limit: 80)) → \(rel)")
        try bundle.reindex(into: i, only: touched)
        try bundle.regenerateIndexes(from: i)
        return rel
    }

    // MARK: Lint

    func lint() throws -> LintResult {
        let i = try open()
        try bundle.reindex(into: i)
        let pages = try bundle.lintPages(from: i)
        let findings = KnowledgeLinter.lint(pages: pages, references: bundle.referencePaths(), reportsBySourceKey: try bundle.reportedReferences(from: i))
        try ensureDirectory(BundleLayout.meta)
        let rel = "\(BundleLayout.meta)/lint-\(OKFDate.day(Date())).md"
        try bundle.write(KnowledgeLinter.render(findings, pageCount: pages.count), to: rel)
        try bundle.appendLog(kind: "lint", text: findings.isEmpty ? "clean (\(pages.count) pages)" : "\(findings.count) findings → \(rel)")
        try bundle.reindex(into: i, only: [rel])
        try bundle.regenerateIndexes(from: i)
        return LintResult(findings: findings, path: rel, pages: pages.count)
    }

    // MARK: Embeddings

    /// Embeds one batch of chunks that have no vector yet. Returns how many were done (0 = nothing left or assets missing).
    func embedBatch(limit: Int = 32) async throws -> Int {
        guard embeddingsEnabled else { return 0 }
        let i = try open()
        let batch = try i.chunksNeedingEmbedding(model: embedder.id, limit: limit)
        guard let first = batch.first else { return 0 }
        guard AppleContextualEmbedding.assetsAvailable(for: first.text) else { throw EmbeddingAssetsMissing(sample: String(first.text.prefix(40))) }
        let vs = try await embedder.embed(batch.map(\.text))
        for (n, v) in vs.enumerated() where n < batch.count { try i.store(embedding: v, chunkID: batch[n].chunkID, model: embedder.id) }
        vectors = try i.loadVectors(model: embedder.id)
        return batch.count
    }

    func pendingEmbeddings() -> Int {
        guard let i = try? open() else { return 0 }
        return (try? i.chunksNeedingEmbedding(model: embedder.id, limit: 100_000).count) ?? 0
    }

    // MARK: Git

    /// "Keep history": one commit per ingest / query / lint, never a push.
    func commit(message: String) {
        let root = bundle.root
        @discardableResult
        func git(_ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", root.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            guard git(["init", "-q"]) == 0 else { return }
        }
        git(["add", "-A"])
        git(["-c", "user.name=Mochlet", "-c", "user.email=mochlet@localhost", "commit", "-q", "-m", message])
    }

    static func kind(forExtension ext: String) -> String {
        switch ext {
        case "pdf": return "PDF"
        case "doc", "docx", "rtf", "odt", "pages": return "Document"
        case "ppt", "pptx", "key": return "Presentation"
        case "xls", "xlsx", "csv", "numbers": return "Spreadsheet"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return "Image"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus": return "Audio"
        case "mp4", "mov", "mkv", "webm", "m4v": return "Video"
        case "html", "htm": return "Web page"
        default: return "File"
        }
    }
}

struct EmbeddingAssetsMissing: Error, CustomStringConvertible {
    var sample: String
    var description: String { "Language assets for on-device embeddings are not installed (\(sample)…)." }
}
