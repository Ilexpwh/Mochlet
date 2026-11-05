import AppKit
import Foundation
import Observation
import MochletCore
import MochletServices

/// A counting semaphore for the main actor: `n` jobs may hold a slot at once.
@MainActor
final class AsyncLimiter {
    private let limit: Int
    private var used = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ limit: Int) { self.limit = limit }
    var isBusy: Bool { used >= limit }

    func acquire() async {
        if used < limit { used += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        used += 1
    }

    func release() {
        used = max(0, used - 1)
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

/// "Eat the file": extract → analyse with the brain → choose a project → file with mirrors → index →
/// integrate into the wiki. Two extractions run at once, one brain call at a time. The slime chews
/// while anything is in flight; the ingest card shows the stage, asks about the project and ends with
/// the result.
@MainActor
@Observable
final class IngestController {
    struct Job: Identifiable, Sendable {
        let id: String
        let input: IngestInput
        let label: String
        let requestedProject: String?
        let from: String
        let force: Bool
        /// Debug: show the project question whatever the router's confidence.
        var alwaysAsk = false
        var project: String?
        var stage: IngestStage = .reading
        var progress: Double = 0
        var detail: String?
        var title: String?
        var summary: String?
        var routing: String?
        var filed: KnowledgeEngine.Filed?
        var integration: String?
        var error: String?
        var warnings: [String] = []
        var priorKeys: [String] = []
        let startedAt = Date()
        var finishedAt: Date?
        var isActive: Bool { stage != .done && stage != .failed }
    }

    struct Question: Sendable {
        var jobID: String
        var question: ProjectQuestion
        var deadline: Date
    }

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private let extractLimiter = AsyncLimiter(2)
    @ObservationIgnored private let brainLimiter = AsyncLimiter(1)
    @ObservationIgnored private var pick: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var pickWork: Task<Void, Never>?
    @ObservationIgnored private var collapseWork: DispatchWorkItem?

    private(set) var jobs: [Job] = []
    private(set) var question: Question?

    init(app: AppCoordinator) { self.app = app }

    var active: [Job] { jobs.filter(\.isActive) }
    var current: Job? { active.first ?? jobs.last }
    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    // MARK: Entry points

    /// Set by the debug channel: the next job asks for its project even when the router is sure.
    var askNext = false

    /// Runs the whole pipeline; returns where the report landed (nil when even the stub failed).
    @discardableResult
    func ingest(_ input: IngestInput, project: String?, from: String, force: Bool = false) async -> KnowledgeEngine.Filed? {
        var job = Job(id: UUID().uuidString, input: input, label: input.label, requestedProject: project, from: from, force: force, project: project)
        if askNext { job.alwaysAsk = true; askNext = false }
        jobs.append(job)
        if jobs.count > 8 { jobs.removeFirst(jobs.count - 8) }
        if active.count == 1 {
            app.slime.stage.main.drop()
            app.notch.chewProgress = 0.02
        }
        collapseWork?.cancel()
        showCard()
        return await run(job.id)
    }

    func retry(_ id: String) {
        guard let j = job(id) else { return }
        Task { await ingest(j.input, project: j.requestedProject, from: j.from, force: true) }
    }

    func retryLast() { if let j = jobs.last { retry(j.id) } }

    /// The project chips on the card (and the debug channel) answer the question with this.
    func choose(_ slug: String?) {
        guard let c = pick else { return }
        pickWork?.cancel()
        pick = nil
        question = nil
        app.window.hold("ingest", false)
        c.resume(returning: slug)
    }

    /// "Change project" after filing: moves the report and teaches the priors.
    func move(_ id: String, toProject slug: String?) async -> KnowledgeEngine.Filed? {
        guard let j = job(id), let f = j.filed else { return nil }
        do {
            let moved = try await app.knowledge.engine.moveReport(f.path, toProject: slug)
            set(id) { $0.filed = moved; $0.project = slug }
            app.knowledge.didFile(moved, commitMessage: "move | \(OneLine.collapse(moved.title, limit: 60))")
            for d in ProjectRouter.priorDeltas(keys: j.priorKeys, chosen: slug ?? ProjectRouter.inboxID, rejected: j.project ?? ProjectRouter.inboxID) {
                try? await app.knowledge.engine.bumpPrior(key: d.key, project: d.project, by: d.delta)
            }
            return moved
        } catch {
            set(id) { $0.error = ErrorText.describe(error) }
            return nil
        }
    }

    func moveLast(toProject slug: String?) async -> KnowledgeEngine.Filed? {
        guard let j = jobs.last(where: { $0.filed != nil }) else { return nil }
        return await move(j.id, toProject: slug)
    }

    // MARK: Pipeline

    private func run(_ id: String) async -> KnowledgeEngine.Filed? {
        guard let job = job(id) else { return nil }
        let engine = app.knowledge.engine
        let ocr = app.settings.knowledgeOCR
        let transcribe = app.settings.knowledgeTranscribe
        let robots = app.settings.knowledgeRobots
        let describeImages = app.settings.knowledgeDescribeImages
        let integrate = app.settings.knowledgeIntegrate
        do {
            // 1. The dedupe key, before any heavy work.
            stage(id, .reading)
            var sourceKey: String
            var resource: String?
            var sha: String?
            switch job.input {
            case .file(let url):
                let s = try await Task.detached { try KnowledgeEngine.sha256(of: url) }.value
                sha = s
                sourceKey = ReportWriter.sourceKey(sha256: s)
                resource = "file://" + url.path
            case .url(let url):
                sourceKey = URLCanonicalizer.arxivID(url.absoluteString).map { "arxiv:" + $0 } ?? ReportWriter.sourceKey(url: url.absoluteString)
                resource = URLCanonicalizer.canonical(url.absoluteString)
            case .text(let t, _):
                sha = t.sha256Hex
                sourceKey = ReportWriter.sourceKey(sha256: t.sha256Hex)
            case .window(_, _, let url, let t):
                sha = ((url ?? "") + t).sha256Hex
                sourceKey = ReportWriter.sourceKey(sha256: sha!)
                resource = url
            }
            if !job.force, let existing = await engine.existingReport(sourceKey: sourceKey) {
                set(id) { $0.stage = .done; $0.progress = 1; $0.filed = existing; $0.title = existing.title; $0.summary = existing.note; $0.finishedAt = Date() }
                finish(id, success: true)
                return existing
            }

            // 2. Extract.
            await extractLimiter.acquire()
            var content: ExtractedContent
            var fetched: URLIngestor.Fetched?
            do {
                defer { extractLimiter.release() }
                (content, fetched) = try await extract(id, job.input, ocr: ocr, transcribe: transcribe, robots: robots)
            }
            if let f = fetched {
                sourceKey = f.sourceKey
                resource = f.canonical
            }
            set(id) { $0.title = content.title; $0.warnings = content.warnings }

            // 3. Analyse.
            stage(id, .analysing)
            let candidates = projectCandidates()
            let brain = LLMClient.brain(app)
            var model: String?
            var draft: ReportDraft
            if let brain, brainLimiter.isBusy { detail(id, "waiting for \(brain.label)") }
            await brainLimiter.acquire()
            do {
                defer { brainLimiter.release() }
                if let brain { detail(id, brain.label) }
                if case .file(let url) = job.input, FileExtractors.kind(of: url) == "image", describeImages, let brain, brain.canSeeImages {
                    detail(id, "describing the image · \(brain.label)")
                    if let d = try? await brain.describeImage(at: url), !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        content = Self.withDescription(content, d)
                        content.extractors.append("vision")
                    }
                }
                if let brain {
                    do {
                        draft = try await analyse(id, content, brain: brain, engine: engine, candidates: candidates, label: job.label, resource: resource)
                        model = brain.label
                    } catch {
                        draft = ReportDraft.fromText(title: content.title, markdown: content.markdown)
                        warn(id, "Analysis failed (\(OneLine.collapse(ErrorText.describe(error), limit: 140))); filed from the text alone.")
                    }
                } else {
                    draft = ReportDraft.fromText(title: content.title, markdown: content.markdown)
                    warn(id, "No brain configured (Settings → Chat); filed from the text alone.")
                }
            }
            draft = Self.tidy(draft, content: content, label: job.label)
            set(id) { $0.title = draft.title; $0.summary = draft.oneLiner }

            // 4. Choose a project.
            var project = job.requestedProject
            if project == nil, !candidates.isEmpty {
                stage(id, .routing)
                project = await route(id, draft: draft, input: job.input, candidates: candidates, brain: brain)
            }
            set(id) { $0.project = project }

            // 5. File and index.
            stage(id, .filing)
            let filing = KnowledgeEngine.Filing(content: content, draft: draft, input: job.input, sourceKey: sourceKey, resource: resource, downloaded: fetched?.downloaded,
                                                snapshotHTML: fetched?.snapshotHTML, project: project, from: job.from, model: model, sha256: sha)
            let filed = try await engine.fileContent(filing)
            if let d = fetched?.downloaded { try? FileManager.default.removeItem(at: d.deletingLastPathComponent()) }
            stage(id, .indexing)
            set(id) { $0.filed = filed }
            app.knowledge.didFile(filed, commitMessage: "ingest | \(OneLine.collapse(filed.title, limit: 60))")

            // 6. Integrate into the wiki.
            if integrate, let brain {
                stage(id, .integrating)
                detail(id, brainLimiter.isBusy ? "waiting for \(brain.label)" : brain.label)
                await brainLimiter.acquire()
                defer { brainLimiter.release() }
                detail(id, brain.label)
                do {
                    let ctx = try await engine.integrationContext(reportPath: filed.path, draft: draft)
                    let plan = try await brain.structured(IntegrationPlan.self, system: ReportPrompts.integratorSystem,
                                                          user: ReportPrompts.integrator(report: ctx.report, reportPath: filed.path, related: ctx.related, existingTitles: ctx.titles),
                                                          schema: Schemas.integration)
                    let outcome = try await engine.applyIntegration(plan, reportPath: filed.path, reportTitle: filed.title)
                    set(id) { $0.integration = outcome.summary.isEmpty ? "nothing to integrate" : outcome.summary }
                    if !outcome.written.isEmpty { app.knowledge.didFile(filed, commitMessage: "integrate | \(OneLine.collapse(filed.title, limit: 60))") }
                } catch {
                    warn(id, "Integration skipped: \(OneLine.collapse(ErrorText.describe(error), limit: 140))")
                }
            }
            set(id) { $0.stage = .done; $0.progress = 1; $0.detail = nil; $0.finishedAt = Date() }
            finish(id, success: true)
            return filed
        } catch {
            // Nothing dropped on the slime is lost: a stub report keeps the source and the reason.
            let reason = OneLine.collapse(ErrorText.describe(error), limit: 200)
            let stub = try? await engine.fileFallback(job.input, project: job.requestedProject, from: job.from, reason: reason)
            if let stub { app.knowledge.didFile(stub, commitMessage: nil) }
            set(id) { $0.stage = .failed; $0.progress = 1; $0.detail = nil; $0.error = reason; $0.filed = stub; $0.finishedAt = Date() }
            app.knowledge.noteIngestError(reason)
            finish(id, success: false)
            return stub
        }
    }

    private func extract(_ id: String, _ input: IngestInput, ocr: Bool, transcribe: Bool, robots: Bool) async throws -> (ExtractedContent, URLIngestor.Fetched?) {
        let onProgress: @Sendable (Double) -> Void = { p in Task { @MainActor in AppCoordinator.shared.ingest.progress(id, p) } }
        switch input {
        case .file(let url):
            stage(id, FileExtractor.stage(for: url))
            let opts = FileExtractor.Options(ocr: ocr, transcribe: transcribe)
            let c = try await Task.detached(priority: .userInitiated) { try await FileExtractor.extract(url, options: opts, progress: onProgress) }.value
            return (c, nil)
        case .url(let url):
            let f = try await URLIngestor.fetch(url, options: URLIngestor.Options(robots: robots, ocr: ocr, publicHostsOnly: self.job(id)?.from == "mcp"), progress: { st, p in
                Task { @MainActor in
                    let ing = AppCoordinator.shared.ingest!
                    ing.stage(id, st)
                    ing.progress(id, p)
                }
            })
            return (f.content, f)
        case .text(let text, let title):
            stage(id, .extracting)
            return (Self.textContent(text, title: title), nil)
        case .window(let title, let appName, let url, let text):
            stage(id, .extracting)
            let t = title.isEmpty ? appName : title
            var md = "# \(t)\n\nApp: \(appName)\n"
            if let url { md += "URL: \(url)\n" }
            md += "\n" + text + "\n"
            return (ExtractedContent(title: t, markdown: md, metadata: ["app": appName], language: LanguageGuess.code(text), extractors: ["window", "ocr"], resourceURL: url), nil)
        }
    }

    private struct Notes: Decodable { var notes: [String] }

    private func analyse(_ id: String, _ content: ExtractedContent, brain: LLMClient, engine: KnowledgeEngine, candidates: [ProjectRouter.Candidate], label: String, resource: String?) async throws -> ReportDraft {
        let probe = OneLine.collapse(content.title + " " + String(content.markdown.prefix(400)), limit: 300)
        let related = (try? await engine.find(probe, k: 5)) ?? []
        let tokens = TokenEstimator.estimate(content.markdown)
        detail(id, brain.label)
        if tokens <= 12_000 {
            return try await brain.structured(ReportDraft.self, system: ReportPrompts.analystSystem,
                                              user: ReportPrompts.analyst(markdown: content.markdown, label: label, resource: resource, projects: candidates, related: related), schema: Schemas.report)
        }
        let windows = Array(ReportPrompts.windows(content.markdown).prefix(12))
        var notes: [[String]] = []
        for (n, w) in windows.enumerated() {
            try Task.checkCancellation()
            detail(id, "part \(n + 1) of \(windows.count) · \(brain.label)")
            progress(id, Double(n) / Double(windows.count))
            let r = try await brain.structured(Notes.self, system: ReportPrompts.analystSystem, user: ReportPrompts.notes(window: w, index: n, count: windows.count, label: label), schema: Schemas.notes)
            notes.append(r.notes)
        }
        detail(id, "writing the report · \(brain.label)")
        return try await brain.structured(ReportDraft.self, system: ReportPrompts.analystSystem,
                                          user: ReportPrompts.reduce(notes: notes, label: label, resource: resource, projects: candidates, related: related), schema: Schemas.report)
    }

    private func route(_ id: String, draft: ReportDraft, input: IngestInput, candidates: [ProjectRouter.Candidate], brain: LLMClient?) async -> String? {
        let engine = app.knowledge.engine
        var host: String?
        var dir: String?
        switch input {
        case .url(let u): host = u.host
        case .file(let u): dir = u.deletingLastPathComponent().path
        case .window(_, _, let u, _): host = u.flatMap { URL(string: $0)?.host }
        case .text: break
        }
        let keys = PriorKeys.keys(host: host, tags: draft.tags, sourceDirectory: dir)
        set(id) { $0.priorKeys = keys }
        let request = ProjectRouter.request(draft: draft, host: host, sourceDirectory: dir, candidates: candidates)
        let priors = (try? await engine.priors()) ?? []
        var answer = await decide(request, brain: brain)
        if answer == nil, let s = draft.suggestedProject, candidates.contains(where: { $0.slug == s }) {
            answer = DecisionAnswer(choice: s, confidence: min(0.95, max(0.5, draft.projectConfidence ?? 0.6)), backend: "analyst")
        }
        let verdict = ProjectRouter.verdict(answer: answer ?? DecisionAnswer(choice: ProjectRouter.inboxID, confidence: 0.34, backend: "none"),
                                            candidates: candidates, priors: priors, priorKeys: keys)
        set(id) { $0.routing = "\(Int((verdict.confidence * 100).rounded()))% · \(verdict.backend)" }
        let always = job(id)?.alwaysAsk == true
        guard always || verdict.ask, let q = always ? verdict.question ?? ProjectRouter.question(from: [], candidates: candidates, suggested: verdict.slug) : verdict.question else { return verdict.slug }
        let picked = await askProject(id, q)
        if picked != verdict.slug {
            for d in ProjectRouter.priorDeltas(keys: keys, chosen: picked ?? ProjectRouter.inboxID, rejected: verdict.slug ?? ProjectRouter.inboxID) {
                try? await engine.bumpPrior(key: d.key, project: d.project, by: d.delta)
            }
        }
        return picked
    }

    /// The project pick card: chips for the likely projects, the suggestion accepted after 10 s.
    private func askProject(_ id: String, _ q: ProjectQuestion) async -> String? {
        question = Question(jobID: id, question: q, deadline: Date().addingTimeInterval(10))
        app.window.hold("ingest", true)
        showCard()
        app.slime.stage.main.trigger(.surprised)
        let suggested = q.suggested
        pickWork = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            self.choose(suggested)
        }
        return await withCheckedContinuation { pick = $0 }
    }

    private func decide(_ r: DecisionRequest, brain: LLMClient?) async -> DecisionAnswer? {
        await Decisions.decide(r, app: app, brain: brain)
    }

    private func projectCandidates() -> [ProjectRouter.Candidate] {
        app.projects.projects.filter { !$0.archived }.map { p in
            ProjectRouter.Candidate(slug: p.slug, name: p.name, description: p.description, tags: p.tags, recentTitles: app.knowledge.recentReportTitles(project: p.slug))
        }
    }

    // MARK: Helpers

    nonisolated static func textContent(_ text: String, title: String?) -> ExtractedContent {
        let parsed = try? OKFDocument.parse(text)
        let body = parsed?.body ?? ((try? OKFDocument.splitFrontmatter(text).body) ?? text)
        let heading = OKFDocument(frontmatter: OKFFrontmatter(type: "x"), body: body).heading
        let t = title ?? parsed?.frontmatter.title ?? heading ?? OneLine.collapse(body.split(separator: "\n").first.map(String.init) ?? "Note", limit: 80)
        return ExtractedContent(title: t, markdown: body.hasSuffix("\n") ? body : body + "\n", language: LanguageGuess.code(String(body.prefix(800))), extractors: ["text"])
    }

    nonisolated static func withDescription(_ c: ExtractedContent, _ description: String) -> ExtractedContent {
        var out = c
        let lines = c.markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let section = "## Description\n\n" + description.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if let h = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            out.markdown = (lines[...h] + [""] + [section] + lines[(h + 1)...]).joined(separator: "\n")
        } else {
            out.markdown = section + "\n" + c.markdown
        }
        return out
    }

    /// Guards against a thin model answer: titles, language, bounded lists.
    nonisolated static func tidy(_ d: ReportDraft, content: ExtractedContent, label: String? = nil) -> ReportDraft {
        var out = d
        if out.title.trimmingCharacters(in: .whitespaces).isEmpty { out.title = content.title }
        out.title = OneLine.collapse(out.title, limit: 140)
        out.title = Self.withoutLabel(out.title, label: label)
        if out.oneLiner.isEmpty { out.oneLiner = OneLine.collapse(out.summary, limit: 140) }
        if out.summary.isEmpty { out.summary = out.oneLiner }
        if !["zh", "en", "ja", "ko", "fr", "de", "es"].contains(out.language) { out.language = content.language ?? (LanguageGuess.code(out.summary)) }
        out.tags = Array(NSOrderedSet(array: out.tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })) as? [String] ?? out.tags
        out.tags = Array(out.tags.prefix(12))
        out.keyPoints = Array(out.keyPoints.prefix(15))
        out.entities = Array(out.entities.prefix(20))
        out.quotes = Array(out.quotes.prefix(8))
        if let a = content.metadata["author"], !a.isEmpty, !out.entities.contains(where: { $0.name.lowercased() == a.lowercased() }) {
            out.entities.append(ReportDraft.Entity(name: a, kind: "person", note: "author"))
        }
        return out
    }

    /// "Roadmap (deck.pptx)" / "deck.pptx — Roadmap" → "Roadmap": the file name is in the frontmatter already.
    nonisolated static func withoutLabel(_ title: String, label: String?) -> String {
        guard let label, !label.isEmpty else { return title }
        var t = title
        for sep in [" (", " [", " — ", " - ", " – ", ": "] {
            if t.lowercased().hasSuffix(sep + label.lowercased() + (sep == " (" ? ")" : sep == " [" ? "]" : "")) {
                t = String(t.dropLast(sep.count + label.count + (sep == " (" || sep == " [" ? 1 : 0)))
            }
        }
        for sep in [" — ", " - ", " – ", ": "] where t.lowercased().hasPrefix(label.lowercased() + sep) {
            t = String(t.dropFirst(label.count + sep.count))
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.lowercased() == label.lowercased() ? title : t
    }

    private func set(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    func stage(_ id: String, _ s: IngestStage) {
        set(id) { $0.stage = s; $0.progress = 0 }
        updateRing(id)
    }

    func progress(_ id: String, _ p: Double) {
        set(id) { $0.progress = min(1, max(0, p)) }
        updateRing(id)
    }

    private func detail(_ id: String, _ text: String?) { set(id) { $0.detail = text } }
    private func warn(_ id: String, _ text: String) { set(id) { $0.warnings.append(text) } }

    private func updateRing(_ id: String) {
        guard let j = job(id), j.isActive else { return }
        let all = IngestStage.allCases
        let next = all.firstIndex(of: j.stage).flatMap { $0 + 1 < all.count ? all[$0 + 1].progressStart : 1 } ?? 1
        app.notch.chewProgress = j.stage.progressStart + j.progress * max(0, next - j.stage.progressStart)
    }

    private func finish(_ id: String, success: Bool) {
        guard active.isEmpty else { return }
        app.slime.stage.main.ingestionFinished(success: success)
        app.notch.chewProgress = nil
        scheduleCollapse()
    }

    private func showCard() {
        if app.notch.view != .chat || app.notch.mode != .expanded { app.window.send(.openExternally(.ingest)) }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.app.notch.view == .ingest, self.question == nil, self.active.isEmpty else { return }
            self.app.window.send(.collapse)
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
    }
}
