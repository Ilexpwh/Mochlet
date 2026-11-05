import AppKit
import Foundation
import MochletCore
import MochletServices
import SlimeKit
import os

private let logger = Logger(subsystem: "com.ilexpwh.Mochlet", category: "signals")

/// AI signals: `~/Mochlet/signals/{sources.json, rubric.md, inbox/}` and `signals.sqlite` under
/// Application Support. A 60 s tick fetches the sources that are due (three at a time), runs the
/// pipeline on what came in, refreshes hotness hourly, writes the daily digest into the knowledge
/// base at the chosen time, and lets the slime react to a story that is suddenly everywhere.
@MainActor
@Observable
final class SignalsController {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Mochlet/signals", isDirectory: true)
    static let storeURL = RelayInstaller.supportDir.appendingPathComponent("signals.sqlite")
    static var sourcesURL: URL { root.appendingPathComponent("sources.json") }
    static var rubricURL: URL { root.appendingPathComponent(Rubric.fileName) }
    static var inboxURL: URL { root.appendingPathComponent("inbox", isDirectory: true) }

    struct Detected: Equatable {
        var url: String
        var feedTitle: String?
        var feedCount: Int
        var feeds: [String]       // "title → url"
        var feedURLs: [String]
        var listSelector: String?
        var listLink: String?
        var listCount: Int
        var samples: [String]
        var error: String?
    }

    private(set) var sources: [SignalSource] = []
    private(set) var rubric = Rubric.parse(Rubric.defaultText)
    private(set) var status = SignalsEngine.Status()
    private(set) var isRunning = false
    private(set) var isComposing = false
    private(set) var isDetecting = false
    private(set) var stage: String?
    private(set) var lastRun: Date?
    private(set) var lastReport: SignalsEngine.RunReport?
    private(set) var lastError: String?
    private(set) var detected: Detected?
    private(set) var importNote: String?
    private(set) var hasPushToken = false
    private(set) var hasSocialDataKey = false
    private(set) var ready = false

    @ObservationIgnored private unowned let app: AppCoordinator
    @ObservationIgnored private var engine: SignalsEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var lastHourly: Date?
    @ObservationIgnored private var lastReaction: Date?
    @ObservationIgnored private var digestAttempted: String?

    init(app: AppCoordinator) {
        self.app = app
    }

    // MARK: - Lifecycle

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.inboxURL, withIntermediateDirectories: true)
        loadSources()
        loadRubric()
        do {
            let e = try SignalsEngine(storePath: Self.storeURL.path, rubric: rubric, sources: sources)
            engine = e
            Task { @MainActor in
                await e.setStageHandler { [weak self] s in
                    Task { @MainActor in
                        guard let self else { return }
                        self.stage = s
                        self.status = await e.status()
                    }
                }
                self.status = await e.status()
                self.ready = true
                self.processInbox()
            }
        } catch {
            lastError = "signals.sqlite: " + ErrorText.describe(error)
            logger.error("store failed: \(ErrorText.describe(error), privacy: .private)")
        }
        watcher = FolderWatcher(root: Self.inboxURL, latency: 1, coalesce: 2) { [weak self] _ in
            Task { @MainActor in self?.processInbox() }
        }
        watcher?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // First tick soon after launch so the card has something to show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        runTask?.cancel()
    }

    var enabled: Bool { app.settings.signalsEnabled }
    var brainLabel: String? { LLMClient.brain(app)?.label }
    var languages: [String] { rubric.languages }
    var pushEndpoint: String? { app.knowledge.mcpPort.map { "http://127.0.0.1:\($0)/api/ingest/items" } }
    var externalSourceID: String { sources.first { $0.kind == .external && $0.enabled }?.id ?? "external" }

    // MARK: - Files

    private func loadSources() {
        if let data = try? Data(contentsOf: Self.sourcesURL), let file = try? JSONDecoder().decode(SourcesFile.self, from: data) {
            sources = file.sources
        } else {
            sources = DefaultSources.make()
            saveSources()
        }
        if !sources.contains(where: { $0.kind == .external }) {
            sources.append(SignalSource(id: "external", name: "Pushed in", kind: .external, tier: .t2, intervalMinutes: 0, tags: ["push"], config: [:]))
            saveSources()
        }
    }

    private func saveSources() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? e.encode(SourcesFile(sources: sources)).write(to: Self.sourcesURL, options: .atomic)
        Task { await engine?.update(sources: sources) }
    }

    private func loadRubric() {
        if let text = try? String(contentsOf: Self.rubricURL, encoding: .utf8), !text.isEmpty {
            rubric = Rubric.parse(text)
        } else {
            try? Rubric.defaultText.write(to: Self.rubricURL, atomically: true, encoding: .utf8)
            rubric = Rubric.parse(Rubric.defaultText)
        }
    }

    /// The rubric file was edited: read it again before the next run.
    func reloadRubric() {
        loadRubric()
        Task { await engine?.update(rubric: rubric) }
    }

    // MARK: - Scheduling

    private func tick(now: Date = Date()) {
        guard enabled, let engine, runTask == nil else { return }
        if ProcessInfo.processInfo.thermalState == .critical { return }
        runTask = Task { @MainActor in
            defer { runTask = nil }
            await self.run(engine: engine, force: false, now: now)
            if lastHourly.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
                await engine.refreshRecentEvents(now: now)
                lastHourly = now
                if Calendar.current.component(.weekday, from: now) == 1, Calendar.current.component(.hour, from: now) == 3 { await engine.prune(now: now) }
            }
            await self.digestIfDue(now: now)
            self.status = await engine.status(now: now)
        }
    }

    /// Fetch what is due (or everything), then the pipeline on what arrived.
    private func run(engine: SignalsEngine, force: Bool, now: Date) async {
        let due = await engine.due(now: now, force: force)
        let pending = await engine.status(now: now).pending
        guard !due.isEmpty || force || pending > 0 else { return }
        isRunning = true
        defer { isRunning = false; stage = nil }
        // Keychain reads happen off the main thread: a re-signed build may be asked for access and must not hold the UI.
        let needsKey = due.contains { $0.kind == .xSearch }
        let keys = needsKey ? await Task.detached { SourceFetcher.Keys(socialData: KeychainStore.get("socialdata")) }.value : SourceFetcher.Keys()
        var fetched = 0, created = 0
        var errors: [String] = []
        stage = "fetching \(due.count) sources"
        await withTaskGroup(of: (SignalSource, SourceFetcher.Pulled?, String?).self) { group in
            var inFlight = 0
            var iterator = due.makeIterator()
            func launch(_ s: SignalSource) {
                group.addTask {
                    let state = await engine.sourceState(s.id)
                    do { return (s, try await SourceFetcher.pull(s, state: state, keys: keys, now: now), nil) }
                    catch { return (s, nil, ErrorText.describe(error)) }
                }
            }
            while inFlight < 3, let s = iterator.next() { launch(s); inFlight += 1 }
            while let (s, pulled, error) = await group.next() {
                inFlight -= 1
                fetched += 1
                let n = await engine.record(pulled, for: s, error: error, now: now)
                created += n
                if let error { errors.append("\(s.name): \(error)"); logger.info("fetch failed \(s.id, privacy: .public): \(error, privacy: .private)") }
                if let next = iterator.next() { launch(next); inFlight += 1 }
            }
        }
        let brain = LLMClient.brain(app)
        var report = await engine.process(brain: brain, budget: app.settings.signalsDailyBudget, now: now)
        report.fetched = fetched
        report.errors = errors.prefix(5) + report.errors
        lastReport = report
        lastRun = now
        lastError = report.errors.first
        logger.info("run: \(fetched) sources, \(created) items, \(report.summary, privacy: .public)")
        react(to: report.exciting, now: now)
    }

    /// Fetch every source and process now.
    func runNow() {
        guard let engine, runTask == nil else { return }
        runTask = Task { @MainActor in
            defer { runTask = nil }
            await self.run(engine: engine, force: true, now: Date())
            self.status = await engine.status()
        }
    }

    func cancelRun() { runTask?.cancel() }

    // MARK: - Reactions

    private func react(to events: [SignalEvent], now: Date) {
        guard app.settings.signalsReactions, let top = events.max(by: { $0.hotness < $1.hotness }) else { return }
        guard !app.meetings.prefs.isQuiet(at: now) else { return }
        if let last = lastReaction, now.timeIntervalSince(last) < 3600 { return }
        lastReaction = now
        app.slime.stage.main.trigger(.excited)
        app.toast("Everyone is on it: \(top.title)", symbol: "antenna.radiowaves.left.and.right", seconds: 4)
    }

    // MARK: - Digest

    private var digestTime: (hour: Int, minute: Int) {
        let parts = app.settings.signalsDigestTime.split(separator: ":").compactMap { Int($0) }
        return (parts.first ?? 8, parts.count > 1 ? parts[1] : 0)
    }

    private func digestIfDue(now: Date) async {
        guard let engine else { return }
        let day = SignalsEngine.day(now)
        guard digestAttempted != day else { return }
        let t = digestTime
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        guard (c.hour ?? 0) * 60 + (c.minute ?? 0) >= t.hour * 60 + t.minute else { return }
        guard await engine.digest(day: day) == nil else { digestAttempted = day; return }
        digestAttempted = day
        await compose(engine: engine, now: now)
    }

    /// Writes today's digest now (again, if it exists).
    func composeDigestNow() {
        guard let engine, !isComposing else { return }
        Task { @MainActor in
            await compose(engine: engine, now: Date())
            self.status = await engine.status()
        }
    }

    private func compose(engine: SignalsEngine, now: Date) async {
        isComposing = true
        defer { isComposing = false; stage = nil }
        stage = "composing the digest"
        let window = (now.addingTimeInterval(-24 * 3600), now)
        let cands = await engine.candidates(window: window)
        let day = SignalsEngine.day(now)
        let shown = await engine.recentlyShown(excludingDay: day)   // recomposing today must not hide today's own picks
        let sel = DigestComposer.select(cands, recentlyShown: shown)
        var overview: String?
        if !sel.all.isEmpty, let brain = LLMClient.brain(app), await engine.usedToday(now: now) < app.settings.signalsDailyBudget {
            let zh = rubric.languages.first == "zh"
            let list = sel.all.prefix(12).map { c in "- " + (zh ? "\(c.titleZH) — \(c.summaryZH)" : "\(c.titleEN) — \(c.summaryEN)") }.joined(separator: "\n")
            let user = "Language: \(zh ? "Chinese (简体中文)" : "English")\n\nToday's items:\n\(list)\n\nWrite the overview."
            if let o = try? await brain.structured(SignalPrompts.Overview.self, system: SignalPrompts.overviewSystem, user: user, schema: SignalPrompts.overviewSchema()) {
                overview = o.overview
                await engine.bump("overview", now: now)
            }
        }
        let seen = await engine.countSince(window.0)
        let doc = DigestComposer.page(date: now, selection: sel, overview: overview, languages: rubric.languages, rubricHash: rubric.hash, itemsSeen: seen,
                                      window: window, by: BundleLayout.generator, now: now)
        do {
            let rel = try await app.knowledge.engine.fileDigest(doc, day: day)
            await engine.saveDigest(day: day, path: rel, items: sel.all.count, hot: sel.hot.count, events: sel.all.map { "\($0.eventID):\($0.eventSources)" }, at: now)
            logger.info("digest \(day, privacy: .public): \(sel.all.count) items, \(sel.hot.count) hot")
            if sel.all.isEmpty { app.toast("Today's signals digest is empty: nothing passed the rubric.", symbol: "antenna.radiowaves.left.and.right") }
        } catch {
            lastError = "digest: " + ErrorText.describe(error)
            logger.error("digest failed: \(ErrorText.describe(error), privacy: .private)")
        }
    }

    // MARK: - Sources

    func toggle(_ id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].enabled.toggle()
        saveSources()
    }

    func setTier(_ id: String, _ tier: SourceTier) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].tier = tier
        saveSources()
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        saveSources()
    }

    /// Looks at a URL: a feed, feeds linked from the page, or a list the extractor can read.
    func detect(_ raw: String) {
        guard !isDetecting else { return }
        isDetecting = true
        detected = nil
        Task { @MainActor in
            let d = await SourceFetcher.detect(raw)
            self.detected = Detected(url: d.url, feedTitle: d.feedTitle, feedCount: d.feedCount, feeds: d.feeds.map { "\($0.title.isEmpty ? "feed" : $0.title) → \($0.url)" },
                                     feedURLs: d.feeds.map(\.url), listSelector: d.list?.itemSelector, listLink: d.list?.linkSelector,
                                     listCount: d.list?.count ?? 0, samples: d.list?.samples ?? [], error: d.error)
            self.isDetecting = false
        }
    }

    func clearDetection() { detected = nil }

    private func newID(_ base: String) -> String {
        var slug = Slug.make(base).lowercased()
        if slug.isEmpty { slug = "source" }
        var id = slug
        var n = 2
        while sources.contains(where: { $0.id == id }) { id = "\(slug)-\(n)"; n += 1 }
        return id
    }

    /// Adds the detected feed (`feedURL`), or the detected list, as a source.
    func addDetected(feedURL: String? = nil, asList: Bool = false, tier: SourceTier = .t2, name: String? = nil) {
        guard let d = detected else { return }
        let host = URL(string: d.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "source"
        if asList, let sel = d.listSelector {
            let s = SignalSource(id: newID("web-" + host), name: name ?? host, kind: .webList, tier: tier, intervalMinutes: 120, tags: [],
                                 config: ["url": .string(d.url), "itemSelector": .string(sel), "linkSelector": .string(d.listLink ?? "a"), "render": .string("auto")])
            sources.append(s)
        } else {
            let url = feedURL ?? (d.feedCount > 0 ? d.url : d.feedURLs.first)
            guard let url else { return }
            let s = SignalSource(id: newID("rss-" + host), name: name ?? d.feedTitle ?? host, kind: .rss, tier: tier, intervalMinutes: 120, tags: [], config: ["feedUrl": .string(url)])
            sources.append(s)
        }
        saveSources()
        detected = nil
        app.toast("Source added. It is fetched on the next tick.", symbol: "antenna.radiowaves.left.and.right")
    }

    /// AIHOT's `industry/sources.json` (or a bare array of sources), merged into ours.
    func importAIHOT(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let incoming = try AIHOTImport.parse(data)
            let (merged, report) = AIHOTImport.merge(incoming, into: sources)
            sources = merged
            saveSources()
            importNote = "\(report.added.count) added, \(report.updated.count) updated, \(report.skipped.count) unchanged" + (report.disabled.isEmpty ? "" : ", \(report.disabled.count) disabled (WeChat or unknown kinds)")
        } catch {
            importNote = "Import failed: " + ErrorText.describe(error)
        }
    }

    func chooseAIHOTFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.message = "Pick AIHOT's industry/sources.json (or any sources.json)"
        if panel.runModal() == .OK, let u = panel.url { importAIHOT(u) }
    }

    // MARK: - Push endpoint and watch folder

    /// `POST /api/ingest/items` with `Authorization: Bearer <token>`: `{items: [{title, url, summary?, published_at?, source?, external_id?}]}` → `{ok, created}`.
    nonisolated static func handlePush(_ req: HTTPRequest) async -> HTTPResponse {
        guard let token = KeychainStore.get("ingest_token"), !token.isEmpty else {
            return .json(Data(#"{"ok":false,"error":"no ingest token (Settings → Signals)"}"#.utf8), status: 503)
        }
        guard req.headers["authorization"] == "Bearer \(token)" else { return .json(Data(#"{"ok":false,"error":"unauthorised"}"#.utf8), status: 401) }
        guard req.body.count <= 2_000_000, let json = JSONValue.parse(req.body) else { return .json(Data(#"{"ok":false,"error":"bad json"}"#.utf8), status: 400) }
        let items = ExternalItem.parse(json)
        guard !items.isEmpty else { return .json(Data(#"{"ok":false,"error":"no items"}"#.utf8), status: 400) }
        guard items.count <= 50 else { return .json(Data(#"{"ok":false,"error":"at most 50 items per call"}"#.utf8), status: 413) }
        let created = await MainActor.run { AppCoordinator.shared.signals?.push(items) }
        guard let created else { return .json(Data(#"{"ok":false,"error":"signals not ready"}"#.utf8), status: 503) }
        return .json(Data("{\"ok\":true,\"created\":\(created)}".utf8))
    }

    /// Items handed in by the push endpoint or a file in the inbox: queued for the next run.
    func push(_ items: [ExternalItem]) -> Int? {
        guard let engine else { return nil }
        let sourceID = externalSourceID
        Task { @MainActor in
            let n = await engine.ingest(items, sourceID: sourceID)
            logger.info("pushed \(items.count) items, \(n) new")
            self.status = await engine.status()
        }
        return items.count
    }

    /// `inbox/*.json` → items, then the file moves to `inbox/done/`.
    func processInbox() {
        guard app.settings.signalsWatchFolder, let engine else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Self.inboxURL, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "json" }
        guard !files.isEmpty else { return }
        let done = Self.inboxURL.appendingPathComponent("done", isDirectory: true)
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        let sourceID = externalSourceID
        Task { @MainActor in
            var total = 0
            for f in files {
                guard let data = try? Data(contentsOf: f), let json = JSONValue.parse(data) else { continue }
                total += await engine.ingest(ExternalItem.parse(json), sourceID: sourceID)
                let dest = done.appendingPathComponent(f.lastPathComponent)
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: f, to: dest)
            }
            if total > 0 { logger.info("inbox: \(total) new items from \(files.count) files") }
            self.status = await engine.status()
        }
    }

    func regeneratePushToken() {
        let token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        // Delete first: an item another build of the app created cannot be updated without a prompt.
        KeychainStore.delete("ingest_token")
        KeychainStore.set(token, account: "ingest_token")
        hasPushToken = true
    }

    func revokePushToken() {
        KeychainStore.delete("ingest_token")
        hasPushToken = false
    }

    /// A curl line with the token, on the clipboard (never shown in the window).
    func copyPushExample() {
        guard let token = KeychainStore.get("ingest_token"), let endpoint = pushEndpoint else { return }
        let line = "curl -s -X POST \(endpoint) -H 'Authorization: Bearer \(token)' -H 'Content-Type: application/json' -d '{\"items\":[{\"title\":\"Example\",\"url\":\"https://example.com/post\",\"summary\":\"…\"}]}'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    /// Settings → Signals asks for these when it opens (the Keychain may prompt once per build).
    func refreshKeychainFlags() {
        Task { @MainActor in
            let (push, social) = await Task.detached { (KeychainStore.exists("ingest_token"), KeychainStore.exists("socialdata")) }.value
            self.hasPushToken = push
            self.hasSocialDataKey = social
        }
    }

    func setSocialDataKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { KeychainStore.delete("socialdata") } else { KeychainStore.set(k, account: "socialdata") }
        hasSocialDataKey = !k.isEmpty
    }

    // MARK: - Opening things

    func openDigest() {
        if let d = status.latestDigest { app.knowledge.openPath(d.path) } else { app.toast("No digest yet. Compose one from Settings → Signals.", symbol: "doc.text") }
    }
    func openFolder() { NSWorkspace.shared.activateFileViewerSelecting([Self.sourcesURL]) }
    func openRubric() { NSWorkspace.shared.open(Self.rubricURL) }
    func openSources() { NSWorkspace.shared.open(Self.sourcesURL) }
    func open(event: SignalEvent) {
        Task { @MainActor in
            guard let engine, let it = await engine.item(event.topItemID), SignalText.isWebURL(it.url), let u = URL(string: it.url) else { return }
            NSWorkspace.shared.open(u)
        }
    }

    /// The card's event rows: title in the rubric's first language.
    func title(for e: SignalEvent) -> String { e.title }

    func refreshStatus() {
        guard let engine else { return }
        Task { @MainActor in self.status = await engine.status() }
    }

    /// Groups the last two weeks again (debug; after a clustering change).
    func reclusterNow() {
        guard let engine, runTask == nil else { return }
        runTask = Task { @MainActor in
            defer { runTask = nil }
            isRunning = true
            stage = "grouping again"
            let n = await engine.recluster(brain: LLMClient.brain(app), budget: app.settings.signalsDailyBudget)
            isRunning = false
            stage = nil
            lastReport = SignalsEngine.RunReport(events: n)
            self.status = await engine.status()
        }
    }

    // MARK: - Debug

    /// Exercises the push endpoint from inside the app (debug channel): two items, the stored token.
    func debugPushTest() async -> String {
        guard let endpoint = pushEndpoint, let url = URL(string: endpoint) else { return "no endpoint" }
        guard let token = await Task.detached(operation: { KeychainStore.get("ingest_token") }).value else { return "no token" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let stamp = Int(Date().timeIntervalSince1970)
        req.httpBody = Data("{\"items\":[{\"title\":\"Push test \(stamp): a lab ships an open model\",\"url\":\"https://example.com/push/\(stamp)\",\"summary\":\"An AI lab released the weights of a new LLM.\"},{\"title\":\"\",\"url\":\"x\"}]}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let bad = try await URLSession.shared.data(for: { var r = req; r.setValue("Bearer nope", forHTTPHeaderField: "Authorization"); return r }())
            return "push: \((resp as? HTTPURLResponse)?.statusCode ?? 0) \(String(decoding: data, as: UTF8.self)) | bad token: \((bad.1 as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            return "push failed: " + ErrorText.describe(error)
        }
    }

    func debugState() -> [String: Any] {
        ["ready": ready, "enabled": enabled, "sources": sources.count, "enabledSources": sources.filter(\.enabled).count, "running": isRunning, "composing": isComposing,
         "stage": stage ?? "", "lastRun": lastRun.map { ISO8601DateFormatter().string(from: $0) } ?? "", "report": lastReport?.summary ?? "", "error": lastError ?? "",
         "itemsToday": status.itemsToday, "acceptedToday": status.acceptedToday, "pending": status.pending, "usage": status.usedCalls, "budget": app.settings.signalsDailyBudget,
         "hot": status.hot.prefix(5).map { ["id": $0.id, "title": $0.title, "hotness": $0.hotness, "sources": $0.sourceCount, "rising": $0.rising, "new": $0.isNew] as [String: Any] },
         "digest": status.latestDigest.map { "\($0.day) \($0.path) items=\($0.items) hot=\($0.hot)" } ?? "", "digestTime": app.settings.signalsDigestTime,
         "detected": detected.map { "\($0.url) feed=\($0.feedCount) feeds=\($0.feedURLs) list=\($0.listSelector ?? "-")×\($0.listCount) err=\($0.error ?? "")" } ?? "",
         "import": importNote ?? "", "pushToken": hasPushToken, "endpoint": pushEndpoint ?? "", "brain": brainLabel ?? "", "rubricHash": String(rubric.hash.prefix(12)),
         "states": sources.map { s in "\(s.id): fetched=\(status.states[s.id]?.fetched ?? 0) fail=\(status.states[s.id]?.failures ?? 0) \(status.states[s.id]?.lastError ?? "")" }]
    }
}
