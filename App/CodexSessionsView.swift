import SwiftUI
import SlimeCore

@MainActor @Observable final class CodexSessionsController {
    var sessions: [StoredCodexSession] = []
    var selectedID: String?
    var selected: StoredCodexSession?
    var history = ""
    var nextList: String?
    var nextHistory: String?
    var busy = false
    var watch = false
    var externalStopped = false
    var message: String?
    var refreshedAt: Date?
    private var projectID: String?
    private var generation = UUID()
    private var catalog: CodexSessionCatalog?
    private var job: Task<Void, Never>?
    private var listCursors: Set<String> = []
    private var historyCursors: Set<String> = []
    func close() {
        generation = UUID(); job?.cancel(); job = nil; busy = false; watch = false
        let old = catalog; catalog = nil
        Task { await old?.stop() }
    }
    func selectProject(_ project: Project?) {
        close(); projectID = project?.id; sessions = []; selectedID = nil; selected = nil
        history = ""; nextList = nil; nextHistory = nil; externalStopped = false; message = nil
        listCursors = []; historyCursors = []
        refreshedAt = nil
    }
    private func connection(project: Project, executable: String) async throws -> CodexSessionCatalog {
        if let catalog { return catalog }
        let opened = try await CodexSessionCatalog.open(executable: executable, project: project)
        if Task.isCancelled { await opened.stop(); throw CancellationError() }
        catalog = opened; return opened
    }
    private func run(project: Project, _ work: @escaping @MainActor (UUID) async throws -> Void) {
        guard !busy, projectID == project.id else { return }
        busy = true; message = nil; let token = generation
        job = Task { @MainActor in
            defer { if generation == token { busy = false; job = nil } }
            do { try await work(token) }
            catch { if generation == token { message = error.localizedDescription; watch = false } }
        }
    }
    func refresh(project: Project, executable: String, more: Bool = false) {
        let cursor = more ? nextList : nil
        run(project: project) { token in
            let reader = try await self.connection(project: project, executable: executable)
            let page = try await reader.list(project: project, after: cursor)
            try Task.checkCancellation(); guard self.generation == token else { return }
            if !more { self.listCursors = [] }
            if let next = page.nextCursor, self.listCursors.contains(next) { throw MochletError.message("Repeated session cursor. Refresh the list.") }
            if let cursor { self.listCursors.insert(cursor) }
            let existing = more ? self.sessions : []
            guard existing.count + page.sessions.count <= 500 else { throw MochletError.message("Session list reached its 500-entry display limit. Narrow the registered project folder.") }
            var ids = Set<String>()
            self.sessions = (existing + page.sessions).filter { ids.insert($0.id).inserted }
              self.nextList = page.nextCursor
              self.refreshedAt = Date()
        }
    }
    func inspect(project: Project, executable: String, older: Bool = false) {
        guard let id = selectedID else { return }
        let cursor = older ? nextHistory : nil
        run(project: project) { token in
            let reader = try await self.connection(project: project, executable: executable)
            let page = try await reader.history(id: id, project: project, after: cursor)
            try Task.checkCancellation(); guard self.generation == token, self.selectedID == id else { return }
            if !older { self.historyCursors = [] }
            if let next = page.nextCursor, self.historyCursors.contains(next) { throw MochletError.message("Repeated history cursor. Refresh the latest activity.") }
            if let cursor { self.historyCursors.insert(cursor) }
            self.selected = page.session; self.history = page.text; self.nextHistory = page.nextCursor
        }
    }
    func importSelection(model: AppModel, showCompanion: @escaping () -> Void) {
        guard let id = selectedID, let project = model.selectedProject, externalStopped else { return }
        let revision = model.composerRevision, taskID = model.selectedTaskID
        run(project: project) { token in
            guard model.draft.isEmpty, model.connectedDraft == nil, !model.preparingSubmission else { throw MochletError.message("Finish your existing draft before choosing a session to resume.") }
            let reader = try await self.connection(project: project, executable: model.codexPath)
            let fresh = try await reader.read(id: id, project: project)
            try Task.checkCancellation()
            guard self.generation == token, self.selectedID == id, self.externalStopped else { return }
            let task = try await model.store.importCodexSession(fresh, project: project, externalClientStopped: true)
            try await model.refresh(); try Task.checkCancellation()
            guard self.generation == token, model.selectedProjectID == project.id, model.selectedTaskID == taskID,
                  model.composerRevision == revision, model.draft.isEmpty, model.connectedDraft == nil, !model.preparingSubmission else {
                throw MochletError.message("The session is saved in Task history. Your current composer was preserved.")
            }
            model.selectedTaskID = task.id
            self.externalStopped = false; self.watch = false
            showCompanion()
        }
    }
}

struct CodexSessionsView: View {
    @Bindable var model: AppModel
    var showCompanion: () -> Void
    @State private var observer = CodexSessionsController()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Codex sessions").font(.largeTitle.bold()); Spacer(); if observer.busy { ProgressView().controlSize(.small) } }
            Text("Browse stored activity from Codex CLI, editor and app-server sessions in this exact project folder. Browsing starts no agent turn.").foregroundStyle(.secondary)
            HStack {
                Picker("Project", selection: $model.selectedProjectID) {
                    Text("Choose a project").tag("")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }.disabled(observer.busy)
                Button("Refresh sessions") { if let project = model.selectedProject { observer.refresh(project: project, executable: model.codexPath) } }
                    .disabled(observer.busy || model.selectedProject == nil)
              }
              if let refreshed = observer.refreshedAt {
                  Text("\(observer.sessions.count) sessions\(observer.nextList == nil ? "" : " loaded") · refreshed \(refreshed.formatted(date: .omitted, time: .standard))")
                      .font(.caption).foregroundStyle(.secondary)
              }
              HSplitView {
                VStack {
                    List(selection: $observer.selectedID) {
                        ForEach(observer.sessions) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).lineLimit(2)
                                Text("\(session.source) · \(session.updatedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).tag(session.id)
                        }
                    }.disabled(observer.busy)
                    if observer.nextList != nil {
                        Button("Load more sessions") { if let project = model.selectedProject { observer.refresh(project: project, executable: model.codexPath, more: true) } }.disabled(observer.busy)
                    }
                }.frame(minWidth: 190, idealWidth: 240)
                VStack(alignment: .leading, spacing: 12) {
                    if let session = observer.selected {
                        Text(session.title).font(.headline)
                        Text(session.id).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Observed \(session.observedAt.formatted()) · this reader reports \(session.serverStatus)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Latest activity") { inspect() }.disabled(observer.busy)
                            if observer.nextHistory != nil { Button("Older turns") { inspect(older: true) }.disabled(observer.busy || observer.watch) }
                            Toggle("Watch every 10s", isOn: $observer.watch).toggleStyle(.checkbox)
                        }
                        ScrollView { Text(observer.history).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        Text("External process liveness is unknown. Answer external approvals/questions in their original client. Stop that client before resuming the same session here.").font(.caption).foregroundStyle(.secondary)
                        Toggle("I stopped this session in its other client", isOn: $observer.externalStopped).toggleStyle(.checkbox).disabled(observer.busy)
                        Button("Prepare exact resume in Companion") { observer.importSelection(model: model, showCompanion: showCompanion) }
                            .disabled(observer.busy || !observer.externalStopped || !session.mayImport)
                    } else {
                        ContentUnavailableView("Select a stored session", systemImage: "text.bubble", description: Text("Refresh to list sessions. History stays read-only until you explicitly prepare a resume and send a new message."))
                    }
                }.padding(.leading, 12).frame(minWidth: 340)
            }
            if let message = observer.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(24)
            .onAppear { observer.selectProject(model.selectedProject) }
            .onChange(of: model.selectedProjectID) { _, _ in observer.selectProject(model.selectedProject) }
            .onChange(of: observer.selectedID) { _, _ in
                observer.selected = nil; observer.history = ""; observer.externalStopped = false; observer.watch = false; inspect()
            }
            .onDisappear { observer.close() }
            .task(id: observer.watch) {
                guard observer.watch else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard observer.watch else { return }; inspect()
                }
            }
    }
    private func inspect(older: Bool = false) {
        if let project = model.selectedProject { observer.inspect(project: project, executable: model.codexPath, older: older) }
    }
}
