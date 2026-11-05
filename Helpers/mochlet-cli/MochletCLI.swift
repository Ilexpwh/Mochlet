// mochlet-cli: work on the knowledge bundle without the app.
//   mochlet-cli reindex [--force]          bring index.sqlite in step with ~/Mochlet/Knowledge
//   mochlet-cli find <query> [-k 8] [--type report]
//   mochlet-cli grep <text>
//   mochlet-cli lint                       write meta/lint-YYYY-MM-DD.md and print the findings
//   mochlet-cli ingest <file> [--project slug] [--title t]   file any readable source (no model: text extraction only)
//   mochlet-cli extract <file>             print what the extractors read (Markdown)
//   mochlet-cli embed [--limit 500]        compute on-device vectors for chunks that lack them
//   mochlet-cli bootstrap                  create the folders, SCHEMA.md and indexes
// Options: --root <folder> (default ~/Mochlet/Knowledge or $MOCHLET_KNOWLEDGE_ROOT), --index <sqlite>.
import Foundation
import MochletCore
import MochletServices

@main
enum MochletCLI {
    static func main() async {
    var args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return v
    }
    func flag(_ name: String) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let defaultRoot = home.appendingPathComponent("Mochlet/Knowledge")
    let rootPath = option("--root") ?? ProcessInfo.processInfo.environment["MOCHLET_KNOWLEDGE_ROOT"] ?? defaultRoot.path
    let root = URL(fileURLWithPath: (rootPath as NSString).expandingTildeInPath).standardizedFileURL
    let indexPath = option("--index") ?? (root == defaultRoot.standardizedFileURL
        ? home.appendingPathComponent("Library/Application Support/Mochlet/index.sqlite").path
        : root.appendingPathComponent(".index.sqlite").path)
    let force = flag("--force")
    let k = Int(option("-k") ?? "8") ?? 8
    let typeFilter = option("--type")
    let project = option("--project")
    let titleOverride = option("--title")
    let limit = Int(option("--limit") ?? "500") ?? 500

    guard let command = args.first else {
        print("usage: mochlet-cli reindex|find|grep|lint|ingest|extract|embed|bootstrap [args] [--root dir] [--index file]")
        exit(2)
    }
    args.removeFirst()

    let bundle = KnowledgeBundle(root: root)
    func openIndex() throws -> KnowledgeIndex {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: indexPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        return try KnowledgeIndex(path: indexPath)
    }

    func printHits(_ hits: [KnowledgeHit]) {
        if hits.isEmpty { print("no hits"); return }
        for (i, h) in hits.enumerated() {
            var loc = "\(h.path):\(h.lineStart)"
            if let p = h.page { loc += " p.\(p)" }
            print("\(i + 1). \(h.title)" + (h.headingPath.isEmpty ? "" : " › \(h.headingPath)") + "  [\(loc)]")
            print("   " + OneLine.collapse(h.text, limit: 220))
        }
    }

    do {
        switch command {
        case "bootstrap":
            let created = try bundle.bootstrap()
            print(created.isEmpty ? "bundle already set up at \(root.path)" : "created \(created.count) items in \(root.path): " + created.joined(separator: ", "))

        case "reindex":
            try bundle.bootstrap()
            let index = try openIndex()
            let report = try bundle.reindex(into: index, force: force)
            try bundle.regenerateIndexes(from: index)
            print("\(report.summary) (\(index.documentCount) pages, \(index.chunkCount) chunks) → \(indexPath)")
            for f in report.failed { print("  ! \(f.path): \(f.error)") }

        case "find":
            let query = args.joined(separator: " ")
            guard !query.isEmpty else { print("find needs a query"); exit(2) }
            let index = try openIndex()
            var vectors: VectorStore?
            var qv: [Float]?
            let embedder = AppleContextualEmbedding()
            if let store = try index.loadVectors(model: embedder.id), store.count > 0, AppleContextualEmbedding.assetsAvailable(for: query) {
                vectors = store
                qv = try? await embedder.embed([query]).first
            }
            let hits = try index.find(query, k: k, filters: FindFilters(types: typeFilter.map { [$0] }, project: project), vectors: vectors, queryVector: qv)
            printHits(hits)

        case "grep":
            let needle = args.joined(separator: " ")
            guard !needle.isEmpty else { print("grep needs text"); exit(2) }
            printHits(try openIndex().grep(needle, limit: 50))

        case "lint":
            let index = try openIndex()
            try bundle.reindex(into: index, force: false)
            let pages = try bundle.lintPages(from: index)
            let refs = bundle.referencePaths()
            let reported = try bundle.reportedReferences(from: index)
            let findings = KnowledgeLinter.lint(pages: pages, references: refs, reportsBySourceKey: reported)
            let page = KnowledgeLinter.render(findings, pageCount: pages.count)
            let rel = "meta/lint-\(OKFDate.day(Date())).md"
            try bundle.write(page, to: rel)
            try bundle.appendLog(kind: "lint", text: findings.isEmpty ? "clean (\(pages.count) pages)" : "\(findings.count) findings → \(rel)")
            try bundle.reindex(into: index, only: [rel])
            try bundle.regenerateIndexes(from: index)
            print(findings.isEmpty ? "clean: \(pages.count) pages" : "\(findings.count) findings → \(rel)")
            for f in findings.prefix(40) { print("  \(f.kind.rawValue): \(f.path) — \(f.detail)") }

        case "extract":
            guard let file = args.first else { print("extract needs a file"); exit(2) }
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let c = try await FileExtractor.extract(url, options: FileExtractor.Options(ocr: true, transcribe: true), progress: nil)
            print("title: \(c.title)")
            print("extractors: \(c.extractors.joined(separator: ", "))  words: \(c.words)  language: \(c.language ?? "?")")
            for (k, v) in c.metadata.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") }
            for w in c.warnings { print("warning: \(w)") }
            print("---")
            print(c.markdown)
        case "ingest":
            guard let file = args.first else { print("ingest needs a file"); exit(2) }
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            try bundle.bootstrap()
            let index = try openIndex()
            let dir = project.map { "projects/\($0)" } ?? "inbox"
            let (refPath, sha) = try bundle.mirror(fileAt: url, into: dir)
            let key = ReportWriter.sourceKey(sha256: sha)
            if let existing = try index.ingestRecord(sourceKey: key), existing.status == "done", let p = existing.path, !force {
                print("already chewed: \(p) (use --force to re-chew)")
                exit(0)
            }
            let content = try await FileExtractor.extract(url, options: FileExtractor.Options(ocr: true, transcribe: true), progress: nil)
            let body = content.markdown
            let title = titleOverride ?? content.title
            var touched: Set<String> = [refPath]
            if !KnowledgeBundle.textReferenceExtensions.contains(url.pathExtension.lowercased()) {
                touched.insert(try bundle.mirror(text: body, name: Slug.make(title, maxLength: 48) + ".md", into: dir).relativePath)
            }
            let draft = ReportDraft.fromText(title: title, markdown: body)
            var prov = ReportProvenance(sourceKey: key, resource: "file://" + url.path, referencePath: refPath, ingestedFrom: "cli", extractors: content.extractors,
                                        words: content.words, project: project, sha256: sha)
            prov.mirrors = touched.subtracting([refPath]).sorted()
            let page = ReportWriter.document(draft, provenance: prov)
            let slug = bundle.uniqueSlug(title, in: dir)
            let rel = "\(dir)/\(slug).md"
            try bundle.write(page, to: rel)
            try index.recordIngest(sourceKey: key, path: rel, status: "done")
            try bundle.appendLog(kind: "ingest", text: "\(title) → \(rel)")
            touched.insert(rel)
            try bundle.reindex(into: index, only: touched)
            try bundle.regenerateIndexes(from: index)
            print("filed \(rel) (source mirrored at \(refPath))")

        case "embed":
            let index = try openIndex()
            let embedder = AppleContextualEmbedding()
            var done = 0
            while done < limit {
                let batch = try index.chunksNeedingEmbedding(model: embedder.id, limit: min(32, limit - done))
                if batch.isEmpty { break }
                let vectors = try await embedder.embed(batch.map(\.text))
                for (i, v) in vectors.enumerated() { try index.store(embedding: v, chunkID: batch[i].chunkID, model: embedder.id) }
                done += batch.count
                print("embedded \(done)…")
            }
            print(done == 0 ? "nothing to embed" : "embedded \(done) chunks with \(embedder.id)")

        default:
            print("unknown command \(command)")
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
    }
}
