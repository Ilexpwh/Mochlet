import CryptoKit
import Foundation
import MochletCore
import MochletServices

/// The engine's side of the ingest pipeline: dedupe keys, filing extracted content with its mirrors,
/// the integration pass, moving a report between projects, priors and the decision cache.
extension KnowledgeEngine {
    struct Filing: Sendable {
        var content: ExtractedContent
        var draft: ReportDraft
        var input: IngestInput
        var sourceKey: String
        var resource: String?
        var downloaded: URL?
        var snapshotHTML: String?
        var project: String?
        var from: String
        var model: String?
        var sha256: String?
    }

    struct IntegrationContext: Sendable {
        var report: OKFDocument
        var related: [(path: String, title: String, type: String, excerpt: String)]
        var titles: [String]
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func existingReport(sourceKey: String) -> Filed? {
        guard let i = try? open(), let rec = try? i.ingestRecord(sourceKey: sourceKey), rec.status == "done", let p = rec.path, exists(p) else { return nil }
        let title = (try? i.document(path: p))?.title ?? p
        return Filed(title: title, path: p, existing: true, note: "Already chewed")
    }

    /// Mirrors the source (original file, HTML snapshot, readable Markdown), writes the report, indexes both.
    func fileContent(_ f: Filing) throws -> Filed {
        let i = try open()
        let dir = directory(forProject: f.project)
        try ensureDirectory(dir)
        var extra: Set<String> = []
        var primary: String?
        var sha = f.sha256
        let base = Slug.make(f.draft.title.isEmpty ? f.content.title : f.draft.title, maxLength: 48)
        switch f.input {
        case .file(let url):
            let (rel, s) = try bundle.mirror(fileAt: url, into: dir)
            primary = rel
            sha = s
            if !KnowledgeBundle.textReferenceExtensions.contains(url.pathExtension.lowercased()) {
                extra.insert(try bundle.mirror(text: f.content.markdown, name: base + ".md", into: dir).relativePath)
            }
        case .url:
            if let d = f.downloaded {
                let (rel, s) = try bundle.mirror(fileAt: d, into: dir)
                primary = rel
                sha = s
            }
            if let html = f.snapshotHTML {
                let rel = try bundle.mirror(text: html, name: base + ".html", into: dir).relativePath
                if primary == nil { primary = rel }
            }
            let (md, s2) = try bundle.mirror(text: f.content.markdown, name: base + ".md", into: dir)
            extra.insert(md)
            if primary == nil { primary = md }
            if sha == nil { sha = s2 }
        case .text(let text, _):
            let (rel, s) = try bundle.mirror(text: text, name: base + ".md", into: dir)
            primary = rel
            sha = s
        case .window:
            let (rel, s) = try bundle.mirror(text: f.content.markdown, name: base + ".md", into: dir)
            primary = rel
            sha = s
        }
        var draft = f.draft
        if let p = f.project { draft.suggestedProject = p }
        var prov = ReportProvenance(sourceKey: f.sourceKey, resource: f.resource, referencePath: primary, ingestedFrom: f.from, model: f.model,
                                    extractors: f.content.extractors, words: f.content.words, project: f.project, sha256: sha)
        prov.mirrors = extra.subtracting([primary ?? ""]).sorted()
        let note = f.content.warnings.isEmpty ? nil : f.content.warnings.joined(separator: " ")
        let filed = try file(draft, provenance: prov, in: dir, index: i, note: note)
        if !extra.isEmpty { try bundle.reindex(into: i, only: extra) }
        return filed
    }

    /// When extraction or analysis fails, keep the source anyway: a stub report with the reason.
    func fileFallback(_ input: IngestInput, project: String?, from: String, reason: String) throws -> Filed {
        switch input {
        case .file(let url): return try addFile(url, project: project, from: from, force: true, reason: reason)
        case .url(let url): return try addLink(url, project: project, from: from, reason: reason)
        case .text(let text, let title): return try addText(text, title: title, project: project, from: from)
        case .window(let title, let app, let url, let text):
            return try addText("# \(title.isEmpty ? app : title)\n\n" + (url.map { "URL: \($0)\n\n" } ?? "") + text, title: title.isEmpty ? app : title, project: project, from: from)
        }
    }

    // MARK: Integration

    func integrationContext(reportPath: String, draft: ReportDraft) async throws -> IntegrationContext {
        let i = try open()
        let report = try OKFDocument.parse(try bundle.read(reportPath))
        var q = draft.title + " " + draft.oneLiner
        if !draft.entities.isEmpty { q += " " + draft.entities.prefix(5).map(\.name).joined(separator: " ") }
        let hits = try await find(OneLine.collapse(q, limit: 300), k: 12,
                                  filters: FindFilters(types: ["entity", "concept", "comparison", "overview", "report", "synthesis", "meeting", "project"], excludePaths: [reportPath]))
        var related: [(path: String, title: String, type: String, excerpt: String)] = []
        var seen: Set<String> = [reportPath]
        for h in hits where !seen.contains(h.path) && !KnowledgeBundle.isReference(h.path) {
            seen.insert(h.path)
            let body = (try? bundle.read(h.path)).flatMap { try? OKFDocument.parse($0).body } ?? ""
            let excerpt = OneLine.collapse(body.split(separator: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: " "), limit: 320)
            related.append((h.path, h.title, h.type, excerpt))
            if related.count == 8 { break }
        }
        let titles = ((try? i.documents(types: ["entity", "concept", "comparison", "overview"])) ?? []).map(\.title)
        return IntegrationContext(report: report, related: related, titles: titles)
    }

    func applyIntegration(_ plan: IntegrationPlan, reportPath: String, reportTitle: String) throws -> Integrator.Outcome {
        let i = try open()
        let catalog = bundle.catalog()
        var touched: Set<String> = []
        let outcome = try Integrator.apply(plan, reportPath: reportPath, reportTitle: reportTitle, catalog: catalog, read: { path in
            guard !KnowledgeBundle.isReference(path), let text = try? bundle.read(path), let doc = try? OKFDocument.parse(text) else { return nil }
            let human = (try? i.document(path: path))?.isHumanOwned ?? false
            return Integrator.Page(path: path, document: doc, isHumanOwned: human)
        }, write: { path, doc in
            try bundle.write(doc, to: path)
            touched.insert(path)
        })
        if let text = try? bundle.read(reportPath), let doc = try? OKFDocument.parse(text) {
            var fm = doc.frontmatter
            fm.mochlet = Self.setting(fm.mochlet, key: "integrated", to: .bool(true))
            try bundle.write(OKFDocument(frontmatter: fm, body: doc.body), to: reportPath)
            touched.insert(reportPath)
        }
        try bundle.appendLog(kind: "integrate", text: "\(reportTitle) → \(outcome.summary.isEmpty ? "no changes" : outcome.summary)")
        try bundle.reindex(into: i, only: touched)
        try bundle.regenerateIndexes(from: i)
        return outcome
    }

    nonisolated static func setting(_ node: YAMLNode?, key: String, to value: YAMLNode?) -> YAMLNode {
        var pairs: [YAMLPair] = []
        if case .mapping(let p)? = node { pairs = p }
        if let value {
            if let idx = pairs.firstIndex(where: { $0.key == key }) { pairs[idx].value = value } else { pairs.append(YAMLPair(key, value)) }
        } else {
            pairs.removeAll { $0.key == key }
        }
        return .mapping(pairs)
    }

    // MARK: Moving between projects

    /// Moves a report (and its mirrored copies) to another project folder or the inbox.
    func moveReport(_ path: String, toProject project: String?) throws -> Filed {
        let i = try open()
        let doc = try OKFDocument.parse(try bundle.read(path))
        let dir = directory(forProject: project)
        guard !path.hasPrefix(dir + "/") else {
            return Filed(title: doc.frontmatter.title ?? path, path: path, existing: true, note: "Already there")
        }
        try ensureDirectory(dir)
        let title = doc.frontmatter.title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let newPath = exists("\(dir)/\(base).md") ? "\(dir)/\(bundle.uniqueSlug(title, in: dir)).md" : "\(dir)/\(base).md"
        var touched: Set<String> = [path, newPath]
        var m = doc.frontmatter.mochlet
        let newDir = "\(dir)/\(BundleLayout.referencesDir)"
        func carry(_ from: String) throws -> String {
            let to = "\(newDir)/\((from as NSString).lastPathComponent)"
            guard exists(from) else { return to }
            try FileManager.default.createDirectory(at: bundle.url(newDir), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: bundle.url(to))
            try FileManager.default.moveItem(at: bundle.url(from), to: bundle.url(to))
            touched.insert(from)
            touched.insert(to)
            return to
        }
        if case .mapping(let pairs)? = m, let ref = pairs.first(where: { $0.key == "reference" }), case .string(let refPath) = ref.value, !refPath.isEmpty {
            m = Self.setting(m, key: "reference", to: .string(try carry(refPath)))
        }
        if case .mapping(let pairs)? = m, let ref = pairs.first(where: { $0.key == "mirrors" }), case .sequence(let items) = ref.value {
            var moved: [YAMLNode] = []
            for item in items { if case .string(let p) = item { moved.append(.string(try carry(p))) } }
            m = Self.setting(m, key: "mirrors", to: .sequence(moved))
        }
        m = Self.setting(m, key: "project", to: project.map { .string($0) })
        var fm = doc.frontmatter
        fm.mochlet = m
        try bundle.write(OKFDocument(frontmatter: fm, body: doc.body), to: newPath)
        try FileManager.default.removeItem(at: bundle.url(path))
        if let key = fm.sources.first?.id { try i.recordIngest(sourceKey: key, path: newPath, status: "done") }
        try bundle.appendLog(kind: "move", text: "\(title) → \(newPath)")
        try bundle.reindex(into: i, only: touched)
        try bundle.regenerateIndexes(from: i)
        return Filed(title: title, path: newPath, existing: false, note: nil)
    }

    // MARK: Priors and decisions

    func priors() throws -> [(key: String, project: String, weight: Double)] { try open().priors() }
    func bumpPrior(key: String, project: String, by delta: Double) throws { try open().bumpPrior(key: key, project: project, by: delta) }
    func cachedDecision(hash: String) -> String? { (try? open().cachedDecision(hash: hash)) ?? nil }
    func cacheDecision(hash: String, backend: String, answerJSON: String) { try? open().cacheDecision(hash: hash, backend: backend, answerJSON: answerJSON) }
}
