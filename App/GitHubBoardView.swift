import SwiftUI
import SlimeCore

struct GitHubBoardRequest: Identifiable { let id = UUID(); let binding: GitHubBinding }

struct GitHubBoardView: View {
    @Bindable var model: AppModel
    let binding: GitHubBinding
    @State private var record: GitHubBoardRecord?
    @State private var url = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showArchived = false
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("GitHub Projects").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("\(binding.repository.full_name) · \(binding.account.login)").foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/users/name/projects/1", text: $url).textFieldStyle(.roundedBorder).disabled(busy)
                Button("Bind / refresh board") { refreshTask = Task { await sync() } }.disabled(busy || url.isEmpty || model.github.busy)
                if busy { ProgressView().controlSize(.small); Button("Cancel") { refreshTask?.cancel() } }
            }
            Text("Read permission for Projects is separate from repository access. This uses the selected gh account and does not change its permissions.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let record {
                HStack {
                    Text(record.snapshot.title).font(.headline)
                    if record.snapshot.closed { Text("Closed board").foregroundStyle(.secondary) }
                    Spacer(); Text("Saved \(record.snapshot.fetchedAt.formatted())").font(.caption)
                }
                Picker("Status field", selection: Binding(get: { record.statusField?.id ?? "" }, set: { id in Task { await mapStatus(id) } })) {
                    Text("No status mapping").tag("")
                    if let field = record.statusField, !record.snapshot.fields.contains(where: { $0.id == field.id && $0.dataType == "SINGLE_SELECT" }) { Text("Unavailable: \(field.name)").tag(field.id) }
                    ForEach(record.snapshot.fields.filter { $0.dataType == "SINGLE_SELECT" }) { Text($0.name).tag($0.id) }
                }.disabled(busy)
                if record.statusField != nil, !record.statusMappingCurrent {
                    HStack {
                        Text("Status field/options changed. Reconfirm the mapping before using its labels.").font(.caption).foregroundStyle(.orange)
                        Button("Reconfirm field") { if let id = record.statusField?.id { Task { await mapStatus(id) } } }.disabled(busy)
                    }
                }
                Toggle("Show archived cards", isOn: $showArchived).toggleStyle(.checkbox)
                List(record.snapshot.items.filter { showArchived || !$0.isArchived }) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(item.content?.title ?? "Inaccessible or removed content").font(.headline)
                            Spacer(); Text(item.content?.kind ?? item.type).font(.caption)
                            if item.isArchived { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let repo = item.content?.repository { Text(repo.nameWithOwner).font(.caption).foregroundStyle(.secondary) }
                        if let status = record.status(for: item) { Text(status).font(.caption) }
                        DisclosureGroup("Field values (\(item.values.count))") {
                            ForEach(item.values) { value in
                                LabeledContent(record.snapshot.fields.first { $0.id == value.field?.id }?.name ?? value.kind, value: value.display).font(.caption)
                            }
                        }
                        HStack {
                            if let link = item.content?.url, let target = URL(string: link), target.host == "github.com", target.scheme == "https" { Link("Open on GitHub", destination: target) }
                            Spacer()
                            if item.canPrepare(binding: binding), !record.snapshot.closed {
                                Button("Prepare issue task") {
                                    Task { await model.github.prepareBoardItem(item, snapshot: record.snapshot, model: model); message = model.github.message }
                                }.disabled(busy || model.github.busy)
                            } else { Text(item.content?.kind == "Issue" ? "Requires an open issue in the bound repository" : "Read-only card").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.vertical, 6)
                }
            } else { ContentUnavailableView("Connect a Projects board", systemImage: "rectangle.split.3x1", description: Text("Paste a user or organization board URL. Board refresh never starts work or changes remote status.")) }
            Text("Status labels are independent of local task state. Draft cards, pull requests and other repositories never silently choose a coding destination. Unsupported complex field values are explicitly labeled.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 860, height: 680)
        .task {
            do { record = try await model.store.githubBoard(binding: binding); url = record?.snapshot.address.url ?? "" }
            catch { message = error.localizedDescription }
        }
        .onDisappear { refreshTask?.cancel() }
    }
    private func sync() async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            let address = try GitHubBoardAddress(url: url)
            let expected = record
            let fresh = try await GitHubBoardClient(executable: model.github.ghPath).snapshot(address: address, binding: binding, expectedID: expected?.snapshot.address == address ? expected?.snapshot.id : nil)
            try Task.checkCancellation()
            record = try await model.store.saveGitHubBoard(fresh, expected: expected)
        } catch { message = error.localizedDescription }
    }
    private func mapStatus(_ id: String) async {
        guard !busy, let expected = record else { return }; busy = true
        defer { busy = false }
        do { record = try await model.store.mapGitHubBoardStatus(fieldID: id.isEmpty ? nil : id, expected: expected); message = nil }
        catch { message = error.localizedDescription }
    }
}
