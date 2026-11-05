import AppKit
import Foundation
import Observation
import MochletCore
import MochletServices

/// The knowledge base as the app sees it: counts, the question being answered, citations, lint
/// results, the MCP endpoint. All file and index work is delegated to `KnowledgeEngine`.
@MainActor
@Observable
final class KnowledgeController {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochlet/Knowledge", isDirectory: true)
    static let indexURL = RelayInstaller.supportDir.appendingPathComponent("index.sqlite")

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored let engine: KnowledgeEngine
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var mcp: KnowledgeMCPServer?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var embedTask: Task<Void, Never>?
    @ObservationIgnored private var reindexTask: Task<Void, Never>?
    @ObservationIgnored private var assetsRequested = false

    let root: URL
    private(set) var ready = false
    private(set) var counts = KnowledgeEngine.Counts()
    private(set) var status: String?
    private(set) var lastError: String?
    /// The question being (or last) answered and what came back.
    private(set) var question = ""
    private(set) var answerText = ""
    private(set) var citations: [Citation] = []
    private(set) var isAnswering = false
    private(set) var answerFiled: String?
    private(set) var lastFiled: KnowledgeEngine.Filed?
    private(set) var lastFindings: [LintFinding] = []
    private(set) var lastLintPath: String?
    private(set) var isLinting = false
    private(set) var mcpPort: UInt16?
    private(set) var mcpError: String?
    private(set) var embeddingNote: String?
    private(set) var pendingEmbeddings = 0
    var query = ""

    init(app: AppCoordinator) {
        self.app = app
        let custom = app.settings.knowledgeRoot.trimmingCharacters(in: .whitespaces)
        root = custom.isEmpty ? Self.defaultRoot : URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        let indexPath = root.standardizedFileURL == Self.defaultRoot.standardizedFileURL ? Self.indexURL.path : root.appendingPathComponent(".index.sqlite").path
        engine = KnowledgeEngine(root: root, indexPath: indexPath)
    }

    var mcpCommand: String { "claude mcp add mochlet -- \"\(RelayInstaller.mcpURL.path)\"" }
    var codexMCPCommand: String { "codex mcp add mochlet -- \"\(RelayInstaller.mcpURL.path)\"" }

    func start() {
        Task { await engine.setEmbeddings(app.settings.knowledgeEmbeddings) }
        reindexTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapAndIndex()
            self.refreshRecentTitles()
            self.startWatcher()
            await self.startMCP()
            self.scheduleEmbeddings()
        }
    }

    func stop() {
        watcher?.stop()
        mcp?.stop()
        answerTask?.cancel()
        embedTask?.cancel()
    }

    // MARK: Index

    private func bootstrapAndIndex() async {
        status = "indexing…"
        do {
            let created = try await engine.bootstrap()
            if !created.isEmpty { NSLog("knowledge: bootstrapped %d items in %@", created.count, root.path) }
            let report = try await engine.reindex()
            counts = await engine.counts()
            status = report.added + report.updated + report.removed == 0 ? nil : report.summary
            ready = true
        } catch {
            lastError = error.localizedDescription
            status = nil
        }
    }

    func reindex(force: Bool = false) {
        guard reindexTask == nil || reindexTask?.isCancelled == true || ready else { return }
        status = "indexing…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await self.engine.reindex(force: force)
                self.counts = await self.engine.counts()
                self.status = report.summary
                self.scheduleEmbeddings()
            } catch {
                self.lastError = error.localizedDescription
                self.status = nil
            }
        }
    }

    private func startWatcher() {
        let w = FolderWatcher(root: root) { paths in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppCoordinator.shared.knowledge.folderChanged(paths) }
            }
        }
        w.start()
        watcher = w
    }

    /// External edits (Obsidian, an agent in the folder, the user) re-index; our own writes and the
    /// generated files are ignored.
    private func folderChanged(_ paths: [String]) {
        Task { [weak self] in
            guard let self else { return }
            var external = false
            for p in paths {
                let name = (p as NSString).lastPathComponent
                if name == "index.md" || name == "log.md" || name.hasPrefix(".") { continue }
                if await self.engine.isOwnWrite(p) { continue }
                external = true
                break
            }
            guard external else { return }
            do {
                let report = try await self.engine.reindex()
                if report.added + report.updated + report.removed > 0 {
                    self.counts = await self.engine.counts()
                    self.status = "folder changed: " + report.summary
                    self.scheduleEmbeddings()
                }
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Embeddings

    func setEmbeddings(_ on: Bool) {
        app.settings.knowledgeEmbeddings = on
        Task { await engine.setEmbeddings(on) }
        if on { scheduleEmbeddings() } else { embedTask?.cancel(); embeddingNote = "off" }
    }

    /// Vectors are computed in the background, 32 chunks at a time, yielding between batches.
    private func scheduleEmbeddings() {
        guard app.settings.knowledgeEmbeddings, embedTask == nil || embedTask?.isCancelled == true else { return }
        embedTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.embedTask = nil }
            var done = 0
            while !Task.isCancelled {
                do {
                    let n = try await self.engine.embedBatch()
                    if n == 0 { break }
                    done += n
                    self.pendingEmbeddings = await self.engine.pendingEmbeddings()
                    self.embeddingNote = "embedding… \(self.pendingEmbeddings) left"
                    await Task.yield()
                } catch let e as EmbeddingAssetsMissing {
                    // First use: ask the system for the language model once per launch, then carry on.
                    guard !self.assetsRequested else { self.embeddingNote = "language assets missing"; return }
                    self.assetsRequested = true
                    self.embeddingNote = "downloading language assets…"
                    let ok = await AppleContextualEmbedding.requestAssets(for: e.sample)
                    if !ok { self.embeddingNote = "language assets unavailable"; return }
                } catch {
                    self.embeddingNote = "embedding failed: \(error.localizedDescription)"
                    return
                }
            }
            self.pendingEmbeddings = await self.engine.pendingEmbeddings()
            self.counts = await self.engine.counts()
            self.embeddingNote = done > 0 ? "\(self.counts.embedded) vectors" : nil
        }
    }

    func requestEmbeddingAssets() {
        embeddingNote = "downloading language assets…"
        Task { [weak self] in
            var ok = true
            for sample in ["The quick brown fox", "知识库里的页面", "日本語のページ", "한국어 페이지"] {
                ok = await AppleContextualEmbedding.requestAssets(for: sample) && ok
            }
            guard let self else { return }
            self.embeddingNote = ok ? "language assets ready" : "some language assets could not be installed"
            self.scheduleEmbeddings()
        }
    }

    // MARK: MCP

    private func startMCP() async {
        _ = RelayInstaller.ensureInstalled("mochlet-mcp")
        let server = KnowledgeMCPServer(backend: KnowledgeMCPBackend())
        do {
            mcpPort = try await server.start()
            mcp = server
            mcpError = nil
        } catch {
            mcpError = error.localizedDescription
        }
    }

    // MARK: Find / answer

    func find(_ query: String, k: Int = 8) async -> [KnowledgeHit] {
        (try? await engine.find(query, k: k)) ?? []
    }

    /// Streams a cited answer into `answerText`.
    func ask(_ q: String) {
        let text = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answerTask?.cancel()
        question = text
        query = text
        answerText = ""
        citations = []
        answerFiled = nil
        lastError = nil
        isAnswering = true
        app.window.hold("knowledge", true)
        app.sessions.publish()
        answerTask = Task { [weak self] in
            guard let self else { return }
            await self.answerStreaming(text, k: 8)
            self.finishAnswer()
        }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        finishAnswer()
    }

    private func finishAnswer() {
        isAnswering = false
        app.window.hold("knowledge", false)
        app.sessions.publish()
    }

    private func answerStreaming(_ text: String, k: Int) async {
        do {
            let hits = try await engine.hits(for: text, k: k)
            if Task.isCancelled { return }
            guard !hits.isEmpty else {
                answerText = "Nothing in the knowledge base matches that yet. Drop a file or a link on me, or ask the chat and file its answer."
                return
            }
            let prompt = AnswerComposer.prompt(question: text, hits: hits, indexSummary: await engine.indexSummary())
            citations = prompt.citations
            let kind = app.chat.providerKind
            guard let provider = app.chat.makeProvider(kind) else {
                lastError = ChatProviderError.noKey(kind.displayName).localizedDescription
                return
            }
            (provider as? CLIChatProvider)?.lean = true
            let request = ChatRequest(messages: [ChatMessage(threadID: "knowledge", role: .user, text: prompt.user)], system: prompt.system,
                                      model: kind.isCLI ? "" : (app.chat.model.isEmpty ? (kind.defaultModels.first ?? "") : app.chat.model))
            for try await ev in provider.stream(request) {
                if Task.isCancelled { break }
                switch ev {
                case .textDelta(let t): answerText += t
                case .failed(let m): lastError = m
                default: break
                }
            }
            let used = AnswerComposer.usedCitations(in: answerText, available: prompt.citations)
            if !used.isEmpty { citations = used }
        } catch {
            if !Task.isCancelled { lastError = error.localizedDescription }
        }
    }

    /// One-shot answer for MCP `search` (no UI state).
    func answer(question: String, k: Int) async -> (answer: String, citations: [Citation], error: String?) {
        do {
            let hits = try await engine.hits(for: question, k: k)
            guard !hits.isEmpty else { return ("Nothing in the knowledge base matches that.", [], nil) }
            let prompt = AnswerComposer.prompt(question: question, hits: hits, indexSummary: await engine.indexSummary())
            let kind = app.chat.providerKind
            guard let provider = app.chat.makeProvider(kind) else { return ("", prompt.citations, ChatProviderError.noKey(kind.displayName).localizedDescription) }
            (provider as? CLIChatProvider)?.lean = true
            let request = ChatRequest(messages: [ChatMessage(threadID: "knowledge", role: .user, text: prompt.user)], system: prompt.system,
                                      model: kind.isCLI ? "" : (app.chat.model.isEmpty ? (kind.defaultModels.first ?? "") : app.chat.model))
            var text = ""
            var failure: String?
            for try await ev in provider.stream(request) {
                switch ev {
                case .textDelta(let t): text += t
                case .failed(let m): failure = m
                default: break
                }
            }
            let used = AnswerComposer.usedCitations(in: text, available: prompt.citations)
            return (text, used.isEmpty ? prompt.citations : used, failure)
        } catch {
            return ("", [], error.localizedDescription)
        }
    }

    /// Saves the current answer as a synthesis page with backlinks.
    func fileAnswer() {
        guard !answerText.isEmpty, !isAnswering, answerFiled == nil else { return }
        let q = question, a = answerText, c = citations
        Task { [weak self] in
            guard let self else { return }
            do {
                let rel = try await self.engine.fileAnswer(question: q, answer: a, citations: c)
                self.answerFiled = rel
                self.counts = await self.engine.counts()
                self.app.slime.stage.main.trigger(.proud)
                self.app.toast("Filed under syntheses/.", symbol: "tray.and.arrow.down")
                self.commitIfEnabled("query | \(OneLine.collapse(q, limit: 60))")
                self.scheduleEmbeddings()
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Lint

    func lint() {
        guard !isLinting else { return }
        isLinting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLinting = false }
            do {
                let r = try await self.engine.lint()
                self.lastFindings = r.findings
                self.lastLintPath = r.path
                self.counts = await self.engine.counts()
                let contradictions = r.findings.filter { $0.kind == .contradiction }.count
                if contradictions > 0 { self.app.slime.stage.main.trigger(.annoyed) }
                self.app.toast(r.findings.isEmpty ? "Lint: clean, \(r.pages) pages." : "Lint: \(r.findings.count) finding\(r.findings.count == 1 ? "" : "s") → meta/", symbol: "stethoscope")
                self.commitIfEnabled("lint | \(r.findings.count) findings")
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: Adding resources (drops, MCP add_resource, debug)

    enum Resource {
        case file(URL)
        case text(String, title: String?)
        case link(URL)
    }

    /// How many sources are being chewed right now.
    var chewing: Int { app.ingest?.active.count ?? 0 }

    /// Files a resource through the ingest pipeline (extract → analyse → route → file → integrate).
    func add(_ resource: Resource, project: String? = nil, from: String = "drop", force: Bool = false) async -> KnowledgeEngine.Filed? {
        let input: IngestInput
        switch resource {
        case .file(let url): input = .file(url)
        case .text(let text, let title): input = .text(text, title: title)
        case .link(let url): input = .url(url)
        }
        return await app.ingest.ingest(input, project: project, from: from, force: force)
    }

    /// The pipeline landed a report (or moved one): refresh counts, embed, commit.
    func didFile(_ filed: KnowledgeEngine.Filed, commitMessage: String?) {
        lastFiled = filed
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            self.counts = await self.engine.counts()
            self.scheduleEmbeddings()
        }
        if let m = commitMessage, !filed.existing { commitIfEnabled(m) }
    }

    func noteIngestError(_ text: String) { lastError = text }

    /// Titles of the last reports filed under a project (context for the project router).
    func recentReportTitles(project: String, limit: Int = 3) -> [String] {
        recentTitles[project] ?? []
    }

    @ObservationIgnored private var recentTitles: [String: [String]] = [:]

    func refreshRecentTitles() {
        Task { [weak self] in
            guard let self else { return }
            var out: [String: [String]] = [:]
            for p in app.projects.projects {
                let docs = (try? await self.engine.documents(pathPrefix: "\(BundleLayout.projects)/\(p.slug)/", types: ["report"])) ?? []
                out[p.slug] = docs.sorted { $0.mtime > $1.mtime }.prefix(3).map(\.title)
            }
            self.recentTitles = out
        }
    }

    private func commitIfEnabled(_ message: String) {
        guard app.settings.knowledgeGit else { return }
        Task(priority: .utility) { await engine.commit(message: message) }
    }

    // MARK: Opening things

    func open(_ c: Citation) {
        let file = root.appendingPathComponent(c.path)
        if let r = c.resource, let u = URL(string: r), u.scheme?.hasPrefix("http") == true, KnowledgeBundle.isReference(c.path) {
            NSWorkspace.shared.open(u)
            return
        }
        openFile(file, line: c.lineStart)
    }

    func openPath(_ relative: String) { openFile(root.appendingPathComponent(relative), line: nil) }

    /// Editors that take a line number get it; everything else opens the file.
    private func openFile(_ url: URL, line: Int?) {
        if let line, line > 0 {
            for (bundleID, flag) in [("com.todesktop.230313mzl4w4u92", "cursor"), ("com.microsoft.VSCode", "code")] {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil,
                   let bin = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"].map({ $0 + "/" + flag }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: bin)
                    p.arguments = ["-g", "\(url.path):\(line)"]
                    if (try? p.run()) != nil { return }
                }
            }
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([root]) }

    /// Where an agent may read files from on the user's behalf: project folders and the usual
    /// document folders, never a dot-directory (.ssh, .config, .claude…) or a system path.
    func isAllowedForAgents(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var roots = ["\(home)/Mochlet", "\(home)/Downloads", "\(home)/Documents", "\(home)/Desktop"]
        roots += app.projects.projects.flatMap { $0.paths }
        return roots.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    // MARK: MCP tools

    func mcpCall(tool: String, arguments a: JSONValue) async -> MCPToolResult {
        func clean(_ path: String) -> String? {
            let p = path.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if p.contains("..") || p.hasPrefix("~") { return nil }
            return p
        }
        func hitsText(_ hits: [KnowledgeHit]) -> (String, JSONValue) {
            if hits.isEmpty { return ("No matching passages.", .object(["hits": .array([])])) }
            var lines: [String] = []
            var structured: [JSONValue] = []
            for (i, h) in hits.enumerated() {
                var loc = "\(h.path):\(h.lineStart)-\(h.lineEnd)"
                if let p = h.page { loc += " p.\(p)" }
                lines.append("[\(i + 1)] \(h.title)" + (h.headingPath.isEmpty ? "" : " › \(h.headingPath)") + " (\(loc))\n\(h.text)")
                structured.append(.object(["path": .string(h.path), "title": .string(h.title), "heading": .string(h.headingPath), "line_start": .number(Double(h.lineStart)),
                                           "line_end": .number(Double(h.lineEnd)), "type": .string(h.type), "score": .number(h.score), "text": .string(h.text)]))
            }
            return (lines.joined(separator: "\n\n"), .object(["hits": .array(structured)]))
        }
        switch tool {
        case "find":
            guard let q = a["query"].string, !q.isEmpty else { return .error("query is required") }
            let k = a["k"].int ?? 8
            let filters = FindFilters(types: a["type"].string.map { [$0] }, project: a["project"].string)
            do {
                let (text, structured) = hitsText(try await engine.find(q, k: max(1, min(50, k)), filters: filters))
                return MCPToolResult(text: text, structured: structured)
            } catch { return .error(error.localizedDescription) }
        case "search":
            guard let q = a["question"].string, !q.isEmpty else { return .error("question is required") }
            let r = await answer(question: q, k: max(1, min(20, a["k"].int ?? 8)))
            if let e = r.error, r.answer.isEmpty { return .error(e) }
            var text = r.answer
            if !r.citations.isEmpty {
                text += "\n\nSources:\n" + r.citations.map { "[\($0.n)] \($0.path):\($0.lineStart)-\($0.lineEnd)" + ($0.heading.isEmpty ? "" : " · \($0.heading)") }.joined(separator: "\n")
            }
            let cites: [JSONValue] = r.citations.map { .object(["n": .number(Double($0.n)), "path": .string($0.path), "title": .string($0.title), "line_start": .number(Double($0.lineStart)), "line_end": .number(Double($0.lineEnd))]) }
            return MCPToolResult(text: text, structured: .object(["answer": .string(r.answer), "citations": .array(cites)]))
        case "read":
            guard let raw = a["path"].string, let p = clean(raw), !p.isEmpty else { return .error("path is required") }
            do {
                var text = try await engine.read(p)
                if let range = a["lines"].string, let dash = range.firstIndex(of: "-"), let from = Int(range[..<dash]), let to = Int(range[range.index(after: dash)...]), from >= 1, to >= from {
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    text = lines.dropFirst(from - 1).prefix(to - from + 1).joined(separator: "\n")
                }
                if text.count > 60_000 { text = String(text.prefix(60_000)) + "\n…(truncated; ask for a line range)" }
                return MCPToolResult(text: text)
            } catch { return .error("Cannot read \(p): \(error.localizedDescription)") }
        case "list":
            let dir = (a["path"].string).flatMap(clean) ?? ""
            let rel = dir.isEmpty ? "index.md" : dir + "/index.md"
            if let text = try? await engine.read(rel), let doc = try? OKFDocument.parse(text) {
                return MCPToolResult(text: doc.body.replacingOccurrences(of: OKFIndexFile.marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let pages = await engine.pagePaths().filter { dir.isEmpty || $0.hasPrefix(dir + "/") }
            return pages.isEmpty ? .error("No folder \(dir.isEmpty ? "/" : dir)") : MCPToolResult(text: pages.joined(separator: "\n"))
        case "tree":
            let t = await engine.tree(depth: max(1, min(6, a["depth"].int ?? 3)))
            var lines: [String] = []
            func walk(_ n: KnowledgeEngine.TreeNode, indent: String) {
                lines.append("\(indent)\(n.path.isEmpty ? "/" : (n.path as NSString).lastPathComponent + "/") (\(n.pages) pages)")
                for c in n.children { walk(c, indent: indent + "  ") }
            }
            walk(t, indent: "")
            return MCPToolResult(text: lines.joined(separator: "\n"))
        case "grep":
            guard let pattern = a["pattern"].string, !pattern.isEmpty else { return .error("pattern is required") }
            do {
                let (text, structured) = hitsText(try await engine.grep(pattern, limit: max(1, min(200, a["limit"].int ?? 50)), pathPrefix: a["path"].string.flatMap(clean)))
                return MCPToolResult(text: text, structured: structured)
            } catch { return .error(error.localizedDescription) }
        case "add_resource":
            let project = a["project"].string
            let filed: KnowledgeEngine.Filed?
            if let u = a["url"].string, let url = URL(string: u), url.scheme?.hasPrefix("http") == true {
                filed = await add(.link(url), project: project, from: "mcp")
            } else if let p = a["path"].string, !p.isEmpty {
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else { return .error("No file at \(url.path)") }
                guard isAllowedForAgents(url) else {
                    return .error("Agents may file files from registered project folders, ~/Mochlet, Downloads, Documents and Desktop only (no hidden folders). Drop the file on Mochlet for anything else.")
                }
                filed = await add(.file(url), project: project.flatMap { KnowledgeBundle.isValidSlug($0) ? $0 : nil }, from: "mcp")
            } else if let t = a["text"].string, !t.isEmpty {
                filed = await add(.text(t, title: a["title"].string), project: project, from: "mcp")
            } else {
                return .error("Give a url, a path or text.")
            }
            guard let filed else { return .error(lastError ?? "Filing failed.") }
            return MCPToolResult(text: (filed.existing ? "Already filed: " : "Filed: ") + "\(filed.title) → \(filed.path)" + (filed.note.map { " (\($0))" } ?? ""),
                                 structured: .object(["path": .string(filed.path), "title": .string(filed.title), "existing": .bool(filed.existing)]))
        case "projects":
            let list = app.projects.projects
            if list.isEmpty { return MCPToolResult(text: "No projects registered.") }
            let text = list.map { "\($0.slug)\t\($0.name)\t\($0.primaryPath ?? "")" + ($0.description.isEmpty ? "" : "\t\($0.description)") }.joined(separator: "\n")
            let structured: [JSONValue] = list.map { .object(["slug": .string($0.slug), "name": .string($0.name), "path": .string($0.primaryPath ?? ""), "description": .string($0.description)]) }
            return MCPToolResult(text: text, structured: .object(["projects": .array(structured)]))
        case "signals_latest":
            let digests = (try? await engine.documents(pathPrefix: BundleLayout.signals + "/", types: ["digest"])) ?? []
            guard let latest = digests.sorted(by: { $0.path > $1.path }).first else {
                return MCPToolResult(text: "No signals digest yet (the AI signals engine arrives with milestone 10).")
            }
            let text = (try? await engine.read(latest.path)) ?? ""
            return MCPToolResult(text: text, structured: .object(["path": .string(latest.path), "title": .string(latest.title)]))
        default:
            return .error("Unknown tool \(tool)")
        }
    }
}

extension KnowledgeController {
    /// Ask-bubble text that is clearly meant for the knowledge base ("kb: …", "知识库：…", "what do I know about …").
    static func question(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        for prefix in ["kb:", "kb ", "knowledge:", "ask kb ", "ask the kb ", "search kb ", "知识库：", "知识库:", "知识库 ", "问知识库", "查知识库"] {
            if lower.hasPrefix(prefix) {
                let q = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return q.isEmpty ? nil : q
            }
        }
        for phrase in ["what do i know about ", "what have i read about ", "did i save anything about ", "我知道的", "我读过的"] where lower.contains(phrase) {
            return t
        }
        return nil
    }
}
