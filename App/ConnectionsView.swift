import SwiftUI
import SlimeCore

@MainActor @Observable final class ConnectionsController {
    let store: Store
    let tokens: TokenConnections
    var accounts: [ConnectedAccount] = []
    var accountID = "" { didSet { if oldValue != accountID { source = nil; collection = ""; objectID = "" } } }
    var account: ConnectedAccount? { accounts.first { $0.id == accountID } }
    var service: TeamService = .slack
    var token = ""
    var collection = ""
    var objectID = ""
    var instruction = ""
    var source: ConnectedSource?
    var busy = false
    var message: String?
    private var operation: Task<Void, Never>?
    init(store: Store) { self.store = store; tokens = TokenConnections(store: store) }
    func load() async {
        do { accounts = try await store.connections().filter { TeamService(rawValue: $0.provider) != nil }; if !accounts.contains(where: { $0.id == accountID }) { accountID = accounts.first?.id ?? "" } }
        catch { message = error.localizedDescription }
    }
    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() } catch is CancellationError { message = "Cancelled." } catch { message = error.localizedDescription }
            await load()
        }
    }
    func cancel() { operation?.cancel() }
    func connect() {
        let service = service, token = token
        run { let account = try await self.tokens.connect(service: service, token: token); self.token = ""; self.accountID = account.id; self.message = "Workspace identity verified. Resource access is checked by the service on each read." }
    }
    func disconnect() {
        guard let account else { return }
        run { try await self.tokens.disconnect(account); self.source = nil; self.message = "Credentials and cached sources removed locally. Task history remains. Connected memories remain for review but are excluded from AI context. Independent copies remain usable. Revoke the token in the service's settings if needed." }
    }
    func bind(_ project: String, enabled: Bool) {
        guard var account else { return }
        if enabled { account.projectIDs.insert(project) } else { account.projectIDs.remove(project) }; account.generation = UUID().uuidString
        run { try await self.store.saveConnection(account) }
    }
    func fetch(account: ConnectedAccount, collection: String, id: String) async throws -> ConnectedSource {
        let source = try await tokens.reader(account).read(account: account, collection: collection, objectID: id)
        try Task.checkCancellation(); try await store.saveSources([source], account: account)
        self.source = source; return source
    }
    func read() {
        guard let account else { return }; let collection = collection.trimmingCharacters(in: .whitespacesAndNewlines), id = objectID.trimmingCharacters(in: .whitespacesAndNewlines)
        run { _ = try await self.fetch(account: account, collection: collection, id: id) }
    }
    func prepare(model: AppModel, openTask: @escaping () -> Void) {
        guard let account, let source, let project = model.selectedProject else { return }
        let revision = model.composerRevision, selectedTask = model.selectedTaskID, provider = model.defaultProvider, instruction = instruction
        run {
            guard model.draft.isEmpty, model.connectedDraft == nil, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MochletError.message("Finish your existing draft and describe the requested work first.") }
            let fresh = try await self.fetch(account: account, collection: source.collection, id: source.remoteID)
            let task = try await self.store.captureSource(fresh, account: account, projectID: project.id, provider: provider)
            try await model.refresh(); try Task.checkCancellation()
            try model.installConnectedDraft(.init(taskID: task.id, projectID: project.id, source: fresh, account: account), instruction: instruction, expectedRevision: revision, expectedTaskID: selectedTask)
            self.message = "Draft prepared. Review its source and destination before Send."; openTask()
        }
    }
    func remember(model: AppModel) {
        guard let account, let source, let project = model.selectedProject else { return }
        run {
            guard account.projectIDs.contains(project.id) else { throw MochletError.message("Bind this account to the selected project first.") }
            let fresh = try await self.fetch(account: account, collection: source.collection, id: source.remoteID)
            var note = KnowledgeNote(scope: project.id, title: fresh.title, body: fresh.body + "\n" + fresh.warnings.joined(separator: "\n"), source: "\(fresh.url) • \(account.label) • \(fresh.revision) • \(fresh.fetchedAt.ISO8601Format())")
            try note.bind(source: fresh, account: account)
            guard await model.knowledge.save(note) else { throw MochletError.message(model.knowledge.message ?? "Memory could not be saved.") }
            self.message = "Project memory copy saved. Edit or forget it in Knowledge & Memory."
        }
    }
    func validateTask(_ id: String) async throws {
        guard let (account, source) = try await store.connectedTaskSource(id), TeamService(rawValue: account.provider) != nil else { return }
        _ = try await tokens.reader(account).read(account: account, collection: source.collection, objectID: source.remoteID)
        try await store.validateConnectedTask(id)
    }
}

struct ConnectionsView: View {
    @Bindable var model: AppModel
    var openTask: () -> Void
    var body: some View {
        @Bindable var connections = model.connections
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("Connections").font(.largeTitle.bold()); Spacer(); if connections.busy { ProgressView().controlSize(.small); Button("Cancel", action: connections.cancel) } }
                Text("Bring a selected Slack thread, Lark message or Linear issue into a project.").foregroundStyle(.secondary)
                DisclosureGroup("Connect a workspace") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Service", selection: $connections.service) { ForEach(TeamService.allCases, id: \.self) { Text($0.title).tag($0) } }
                        SecureField(connections.service == .linear ? "Personal API key" : "User access token", text: $connections.token)
                        Text(setup(connections.service)).font(.callout).foregroundStyle(.secondary)
                        Button("Verify and save in Keychain", action: connections.connect).disabled(connections.token.isEmpty)
                        Text("Mochlet does not obtain broader permissions from a token. Resource access is enforced by the service. Expired tokens must be replaced; automatic OAuth renewal is not implemented for these connectors.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10).disabled(connections.busy)
                }
                if !connections.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Picker("Account", selection: $connections.accountID) { ForEach(connections.accounts) { Text($0.provider.capitalized + " • " + $0.label).tag($0.id) } }
                            Button("Disconnect locally", action: connections.disconnect)
                        }
                        if let account = connections.account {
                            Text("Verified identity: " + account.remoteID).font(.caption).textSelection(.enabled)
                            DisclosureGroup("Projects this connection can supply context to") {
                                ForEach(model.projects) { project in Toggle(project.name, isOn: Binding(get: { account.projectIDs.contains(project.id) }, set: { connections.bind(project.id, enabled: $0) })) }
                            }
                            Divider()
                            if account.provider == "slack" {
                                TextField("Channel ID (C…, G… or D…)", text: $connections.collection)
                                TextField("Parent message timestamp (e.g. 1730000000.123456)", text: $connections.objectID)
                            } else if account.provider == "linear" {
                                TextField("Issue UUID or identifier (e.g. ENG-123)", text: $connections.objectID)
                            } else {
                                TextField("Chat ID (optional, checked when supplied)", text: $connections.collection)
                                TextField("Message ID (om_…)", text: $connections.objectID)
                            }
                            Button("Read selected source", action: connections.read).buttonStyle(.borderedProminent).disabled(connections.objectID.isEmpty)
                            if let source = connections.source {
                                Text(source.title).font(.title2.bold()).textSelection(.enabled)
                                Text("Retrieved \(source.fetchedAt.formatted()) • source \(source.remoteID)").font(.caption).foregroundStyle(.secondary)
                                ForEach(source.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                                if let url = URL(string: source.url), url.scheme == "https" { Link("Source locator", destination: url) }
                                Text(source.body).font(.body).textSelection(.enabled).lineLimit(40)
                                Picker("Destination project", selection: $model.selectedProjectID) { Text("Choose project").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }
                                TextField("What should the agent do with this source?", text: $connections.instruction, axis: .vertical).lineLimit(2...5)
                                HStack {
                                    Button("Prepare task draft") { connections.prepare(model: model, openTask: openTask) }
                                    Button("Save project memory copy") { connections.remember(model: model) }
                                }.disabled(!account.projectIDs.contains(model.selectedProjectID))
                                Text("Refreshing never starts work or sends a message. Task drafts use \(model.defaultProvider.title) for new tasks and preserve the original agent on existing tasks.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(connections.busy)
                }
                if let message = connections.message { Text(message).font(.callout).textSelection(.enabled) }
            }.padding(28).frame(maxWidth: 1000, alignment: .leading)
        }
    }
    private func setup(_ service: TeamService) -> String {
        switch service {
        case .slack: "Use a Slack app user OAuth token with history access to the conversation. Public/private channels, direct messages and Slack Connect have different membership and app-policy limits. Files and linked content are not fetched."
        case .linear: "Create a read-only personal API key in Linear Security & access for the intended workspace and teams. Mochlet verifies the viewer and organization before reading an issue."
        case .lark, .feishu: "Use a current user_access_token for your app with message-read permission. Choose the matching Lark or Feishu region. Tenant/app tokens are not accepted by this user-identity flow. Restricted or invisible messages remain inaccessible."
        }
    }
}
