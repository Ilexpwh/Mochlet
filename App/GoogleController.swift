import SwiftUI
import SlimeCore

@MainActor @Observable final class GoogleController {
    let store: Store
    let oauth: GoogleOAuth
    var accounts: [ConnectedAccount] = []
    var accountID = "" { didSet { if oldValue != accountID { sources = []; selected = nil; calendars = []; calendarID = ""; answer = nil } } }
    var account: ConnectedAccount? { accounts.first { $0.id == accountID } }
    var sources: [ConnectedSource] = []
    var selected: ConnectedSource?
    var calendars: [JSONValue] = []
    var calendarID = "" { didSet { availability = nil; if oldValue != calendarID { clearCalendarResults() } } }
    var availability: String?
    var service = "gmail" { didSet { sources = []; selected = nil; answer = nil; calendarRecordsMode = false; calendarSyncSummary = nil } }
    var calendarRecordsMode = false
    var calendarSyncSummary: String?
    var calendarCancellations: [GoogleCalendarCancellation] = []
    var calendarRecordQuery = "" { didSet { displayLimit = 100 } }
    var displayLimit = 100
    var filteredSources: [ConnectedSource] {
        guard calendarRecordsMode, !calendarRecordQuery.isEmpty else { return sources }
        return sources.filter { $0.title.localizedCaseInsensitiveContains(calendarRecordQuery) || $0.body.localizedCaseInsensitiveContains(calendarRecordQuery) }
    }
    var visibleSources: [ConnectedSource] { Array(filteredSources.prefix(displayLimit)) }
    var query = "newer_than:7d"
    var driveQuery = ""
    var agendaStart = Date() { didSet { availability = nil } }
    var clientID = UserDefaults.standard.string(forKey: "googleDesktopClientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID, forKey: "googleDesktopClientID") }
    }
    var clientSecret = ""
    var mailPermission = true
    var calendarPermission = true
    var drivePermission = false
    var sendPermission = false
    var composePermission = false
    var eventWritePermission = false
    var busy = false
    var message: String?
    var answer: KnowledgeAnswer?
    var taskInstruction = ""
    private var operation: Task<Void, Never>?
    init(store: Store) { self.store = store; oauth = GoogleOAuth(store: store) }
    func load() async {
        do {
            accounts = try await store.connections().filter { $0.provider == "google" }
            if !accounts.contains(where: { $0.id == accountID }) { accountID = accounts.first?.id ?? "" }
            await loadSavedCalendars()
        } catch { message = error.localizedDescription }
    }
    func loadSavedCalendars() async {
        guard calendars.isEmpty, let account else { return }
        do {
            let saved = try await store.savedCalendarIDs(account: account)
            guard self.accountID == account.id, calendars.isEmpty else { return }
            calendars = saved.map { .object(["id": .string($0), "summary": .string($0 + " (saved)")]) }
            if calendarID.isEmpty { calendarID = saved.first ?? "" }
        } catch { message = error.localizedDescription }
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { message = "Cancelled." }
            catch { message = error.localizedDescription }
            await load()
        }
    }
    func cancel() { operation?.cancel(); oauth.cancel() }
    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines), secret = clientSecret
        var scopes = Set<String>()
        if mailPermission { scopes.insert(GoogleScope.mail) }
        if calendarPermission { scopes.insert(GoogleScope.calendar) }
        if drivePermission { scopes.insert(GoogleScope.drive) }
        if sendPermission { scopes.insert(GoogleScope.send); scopes.insert(GoogleScope.mail) }
        if composePermission { scopes.insert(GoogleScope.compose); scopes.insert(GoogleScope.mail) }
        if eventWritePermission { scopes.insert(GoogleScope.calendarWrite); scopes.insert(GoogleScope.calendar) }
        run {
            let account = try await self.oauth.connect(clientID: id, secret: secret.isEmpty ? nil : secret, scopes: scopes)
            self.clientSecret = ""; self.accountID = account.id
            self.message = "Connected. Only permissions actually granted by Google are enabled."
        }
    }
    func disconnect() {
        guard let account else { return }
        run {
            try await self.oauth.disconnect(account); self.sources = []; self.selected = nil; self.answer = nil
            self.message = "Disconnected locally. Cached sources were deleted. Connected memories remain for review but are excluded from AI context. Independent copies and task history remain; revoke remote access in your Google account if desired."
        }
    }
    func bind(projectID: String, enabled: Bool) {
        guard var account else { return }
        if enabled { account.projectIDs.insert(projectID) } else { account.projectIDs.remove(projectID) }
        account.generation = UUID().uuidString
        run { try await self.store.saveConnection(account); self.message = "Project access updated." }
    }
    func reader(_ account: ConnectedAccount, scope: String) async throws -> GoogleReader {
        GoogleReader(account: account, token: try await oauth.token(for: account, scope: scope))
    }
    func search() {
        guard let account else { return }
        let service = service, query = query, driveQuery = driveQuery, calendarID = calendarID, start = agendaStart
        run {
            let result: [ConnectedSource]
            switch service {
            case "gmail": result = try await self.reader(account, scope: GoogleScope.mail).mail(query: query)
            case "drive": result = try await self.reader(account, scope: GoogleScope.drive).drive(query: driveQuery)
            default:
                guard !calendarID.isEmpty else { throw MochletError.message("Choose a calendar first.") }
                let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
                result = try await self.reader(account, scope: GoogleScope.calendar).agenda(calendarID: calendarID, from: start, to: end)
            }
            try Task.checkCancellation(); try await self.store.saveSources(result, account: account)
            self.sources = result; self.selected = nil; self.answer = nil; self.displayLimit = 100
            self.calendarRecordsMode = false; self.calendarSyncSummary = nil
            self.message = "\(result.count) items retrieved from \(account.label)."
        }
    }
    private func clearCalendarResults() {
        sources = []; selected = nil; answer = nil; calendarSyncSummary = nil; calendarRecordsMode = false
        calendarRecordQuery = ""; displayLimit = 100; calendarCancellations = []
    }
    private func showCalendarSnapshot(_ snapshot: GoogleCalendarSnapshot, account: ConnectedAccount) {
        sources = snapshot.records; selected = nil; answer = nil; calendarRecordsMode = true; displayLimit = 100
        calendarRecordQuery = ""
        calendarCancellations = snapshot.cancelledOccurrences
        calendarSyncSummary = "Saved records: \(snapshot.records.count) active · cancelled occurrences: \(snapshot.cancelledOccurrences.count) · \(account.label) • synchronized \(snapshot.syncedAt.formatted()). Recurring series are not expanded. Use Refresh agenda for occurrences or Check availability for busy time."
    }
    func syncCalendar() {
        guard let account, !calendarID.isEmpty else { return }
        let calendar = calendarID
        run {
            self.clearCalendarResults()
            let snapshot = try await self.reader(account, scope: GoogleScope.calendar).syncCalendar(calendarID: calendar, store: self.store)
            try Task.checkCancellation()
            self.showCalendarSnapshot(snapshot, account: account)
            self.message = "Calendar synchronized. Deleted records were removed from its cache. No events were changed in Google."
        }
    }
    func loadCalendarSnapshot() {
        guard let account, !calendarID.isEmpty else { return }
        let calendar = calendarID
        run {
            self.clearCalendarResults()
            guard let snapshot = try await self.store.calendarSnapshot(account: account, calendarID: calendar), snapshot.accountGeneration == account.generation else {
                throw MochletError.message("No saved records for this calendar and current account permissions. Synchronize first.")
            }
            self.showCalendarSnapshot(snapshot, account: account)
            self.message = "Loaded saved records. These may be out of date; current content is checked before task or memory capture."
        }
    }
    func checkAvailability() {
        guard let account else { return }
        let calendar = calendarID, start = agendaStart
        run {
            self.availability = nil
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            let result = try await self.reader(account, scope: GoogleScope.calendar).freeBusy(calendarID: calendar, from: start, to: end)
            try Task.checkCancellation()
            self.availability = "Calendar: \(calendar) • retrieved \(Date().formatted())\n" + (result["busy"].array.isEmpty ? "No busy intervals reported in this seven-day range." : result["busy"].formatted)
        }
    }
    func loadCalendars() {
        guard let account else { return }
        run {
            let calendars = try await self.reader(account, scope: GoogleScope.calendar).calendars()
            try Task.checkCancellation(); self.calendars = calendars
            if !calendars.contains(where: { $0["id"].string == self.calendarID }) { self.calendarID = calendars.first?["id"].string ?? "" }
        }
    }
    func readSource(_ source: ConnectedSource, account: ConnectedAccount) async throws -> ConnectedSource {
        guard source.accountID == account.id else { throw MochletError.message("This source belongs to another account.") }
        let result: ConnectedSource
        switch source.service {
        case "gmail": result = try await reader(account, scope: GoogleScope.mail).thread(source.remoteID)
        case "drive": result = try await reader(account, scope: GoogleScope.drive).driveFile(source.remoteID)
        case "calendar": result = try await reader(account, scope: GoogleScope.calendar).event(calendarID: source.collection, id: source.remoteID)
        default: throw MochletError.message("Unsupported Google source.")
        }
        return result
    }
    func fresh(_ source: ConnectedSource, account: ConnectedAccount) async throws -> ConnectedSource {
        guard source.accountID == account.id else { throw MochletError.message("Select a source from this account.") }
        let result = try await readSource(source, account: account)
        try Task.checkCancellation(); try await store.saveSources([result], account: account)
        selected = result; answer = nil
        if let index = sources.firstIndex(where: { $0.id == result.id }) { sources[index] = result }
        return result
    }
    func validateTask(_ id: String) async throws {
        guard let (account, source) = try await store.connectedTaskSource(id), account.provider == "google" else { return }
        // Recheck remote access before an agent receives queued source content.
        switch source.service {
        case "gmail": _ = try await reader(account, scope: GoogleScope.mail).thread(source.remoteID)
        case "drive": _ = try await reader(account, scope: GoogleScope.drive).driveFile(source.remoteID)
        case "calendar": _ = try await reader(account, scope: GoogleScope.calendar).event(calendarID: source.collection, id: source.remoteID)
        default: throw MochletError.message("Unsupported source permission.")
        }
        try await store.validateConnectedTask(id)
    }
    func read() {
        guard let account, let selected else { return }
        run { _ = try await self.fresh(selected, account: account) }
    }
    func prepare(model: AppModel, openTask: @escaping () -> Void) {
        guard let account, let selected, let project = model.selectedProject else { return }
        let instruction = taskInstruction.trimmingCharacters(in: .whitespacesAndNewlines), provider = model.defaultProvider
        let composerRevision = model.composerRevision, selectedTaskID = model.selectedTaskID
        run {
            guard !instruction.isEmpty else { throw MochletError.message("Describe what you want the agent to do with this source.") }
            guard model.draft.isEmpty, model.connectedDraft == nil, !model.preparingSubmission else { throw MochletError.message("Finish or clear your existing Companion draft before preparing another task.") }
            let source = try await self.fresh(selected, account: account)
            let task = try await self.store.captureSource(source, account: account, projectID: project.id, provider: provider)
            guard task.id != model.activeTaskID, task.state != .queued else { throw MochletError.message("This source already has an active or queued task. Wait for it to finish before preparing a follow-up.") }
            try await model.refresh()
            try Task.checkCancellation()
            try model.installConnectedDraft(.init(taskID: task.id, projectID: project.id, source: source, account: account),
                instruction: instruction, expectedRevision: composerRevision, expectedTaskID: selectedTaskID)
            self.message = "Task draft prepared. Review its destination and Send when ready."; openTask()
        }
    }
    func remember(model: AppModel) {
        guard let account, let selected, let project = model.selectedProject else { return }
        run {
            guard account.projectIDs.contains(project.id) else { throw MochletError.message("Bind this account to the project first.") }
            let source = try await self.fresh(selected, account: account)
            var note = KnowledgeNote(scope: project.id, title: source.title, body: source.body + "\n\n" + source.warnings.joined(separator: "\n"), source: "\(source.url) • account \(account.label) • revision \(source.revision) • retrieved \(source.fetchedAt.ISO8601Format())")
            try note.bind(source: source, account: account)
            guard await model.knowledge.save(note) else { throw MochletError.message(model.knowledge.message ?? "Memory could not be saved.") }
            self.message = "Saved an explicit project memory copy. Edit or forget it in Knowledge & Memory."
        }
    }
    func summarize(speech: SpeechController) {
        guard let account, let selected else { return }
        run {
            let source = try await self.fresh(selected, account: account)
            let modelID = speech.analysisModel
            let catalog = try await speech.service.models(transcription: false)
            guard catalog.contains(where: { $0.id == modelID && $0.inputModalities.contains("text") && $0.outputModalities.contains("text") }) else { throw MochletError.message("Choose an available text analysis model in Speech & Models.") }
            let note = KnowledgeNote(scope: "connected", title: source.title, body: source.body + "\nSource limitations: " + source.warnings.joined(separator: "; "), source: source.url)
            let prompt = try KnowledgeAnswer.prompt(question: "Summarize this source. Distinguish facts, proposals, and unanswered questions. Explain any incomplete export or missing attachment.", notes: [note])
            let text = try await speech.service.answer(prompt: prompt, model: modelID, key: speech.key())
            try Task.checkCancellation()
            guard try await self.store.connections().contains(account) else { throw MochletError.message("The account changed during analysis.") }
            self.answer = try KnowledgeAnswer.decode(text, notes: [note])
            self.message = "Summary of the source retrieved at \(source.fetchedAt.formatted())."
        }
    }
}
