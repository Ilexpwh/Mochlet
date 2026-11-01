import SwiftUI
import SlimeCore

struct GitHubPublicationView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var taskID = ""
    @State private var base = "main"
    @State private var title = ""
    @State private var description = ""
    @State private var evidence = ""
    @State private var records: [Publication] = []
    @State private var message: String?
    private var selected: Publication? { records.first { $0.plan.taskID == taskID } }
    private var eligible: [WorkTask] {
        model.tasks.filter { $0.projectID == model.github.selectedProjectID && model.taskWorkspaces[$0.id] != nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Review & publish").font(.title.bold())
                Spacer()
                if model.github.busy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.disabled(model.github.busy)
            }
            Picker("Issue task", selection: $taskID) {
                Text("Choose a task").tag("")
                ForEach(eligible) { Text($0.title).tag($0.id) }
            }.disabled(model.github.busy)
            if let publication = selected {
                review(publication)
            } else {
                Text("Finish the task and commit its changes in its isolated workspace. This preview publishes committed content only. The agent can prepare the commit through its normal approval flow.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Target branch", text: $base)
                TextField("PR title", text: $title)
                Text("Description").font(.headline)
                TextEditor(text: $description).accessibilityLabel("Pull request description").frame(height: 100).border(.quaternary)
                Text("Test evidence or explicit untested reason").font(.headline)
                TextEditor(text: $evidence).accessibilityLabel("Validation evidence").frame(height: 70).border(.quaternary)
                Button("Prepare exact commit preview") { prepare() }
                    .disabled(model.github.busy || taskID.isEmpty || title.isEmpty || evidence.isEmpty)
                Spacer(minLength: 0)
            }
            if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(24).frame(width: 760, height: 660)
        .textFieldStyle(.roundedBorder)
        .interactiveDismissDisabled(model.github.busy)
        .task { await reload(); taskID = eligible.first(where: { $0.id == model.selectedTaskID })?.id ?? eligible.first?.id ?? "" }
        .onChange(of: taskID) { _, id in
            if let task = eligible.first(where: { $0.id == id }) { title = task.title }
            message = nil
        }
        .onDisappear { model.github.publicationTask?.cancel() }
    }
    @ViewBuilder private func review(_ value: Publication) -> some View {
        let plan = value.plan
        Text("\(plan.binding.repository.full_name) · \(plan.binding.account.login)").font(.headline)
        Text("\(plan.workspace.branch) → \(plan.baseBranch)").font(.caption.monospaced()).textSelection(.enabled)
        Text("Reviewed commit: \(plan.headSHA)").font(.caption.monospaced()).textSelection(.enabled)
        Text(status(value)).foregroundStyle(.secondary)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.title).font(.headline)
                Text(plan.remoteBody).textSelection(.enabled)
                Divider()
                Text(plan.review).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: .infinity)
        HStack {
            if value.state == .prepared {
                Button("Replace preview") { discardPreview(value) }.disabled(model.github.busy)
                Spacer()
                Button("Push reviewed commit & create draft PR") { publish(value) }.disabled(model.github.busy)
                    .buttonStyle(.borderedProminent)
            } else if value.state == .ready {
                Button("Review again · keep pushed branch") { discardPreview(value) }.disabled(model.github.busy)
                Button("Create draft PR for pushed commit") { publish(value) }.disabled(model.github.busy)
            }
            if value.state != .prepared {
                Button(value.state == .published ? "Refresh remote state" : "Reconcile without writing") { reconcile(value) }.disabled(model.github.busy)
            }
            if let receipt = value.receipt, let url = URL(string: receipt.html_url), url.scheme == "https", url.host == "github.com" {
                Link("Open PR #\(receipt.number)", destination: url)
            }
        }
    }
    private func status(_ value: Publication) -> String {
        switch value.state {
        case .prepared: "Preview only · expires after 15 minutes. Publishing creates a branch and a draft PR. It does not merge or close the issue."
        case .pushing: "Push outcome unresolved. Reconcile the remote branch before continuing."
        case .ready: "Reviewed commit is on GitHub. Creating the draft PR requires the explicit action below."
        case .creating: "PR creation outcome unresolved. Reconciliation only reads GitHub; it never repeats creation."
        case .published:
            if let receipt = value.receipt {
                "Remote PR: \(receipt.merged_at == nil ? receipt.state : "merged") · \(receipt.draft ? "draft" : "ready for review")\(receipt.head.sha == value.plan.headSHA ? "" : " · head changed since publication"). Local task state is unchanged."
            } else { "Published; refresh remote state." }
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !model.github.busy else { return }; model.github.busy = true; message = nil
        model.github.publicationTask = Task { @MainActor in
            defer { model.github.busy = false; model.github.publicationTask = nil }
            do { try await work() } catch { message = error.localizedDescription }
            await reload()
        }
    }
    private func reload() async {
        do { records = try await model.store.publications() } catch { message = error.localizedDescription }
    }
    private func publisher() async throws -> GitHubPublisher { try await GitHubPublisher.authenticated(store: model.store, executable: model.github.ghPath) }
    private func prepare() {
        guard let task = eligible.first(where: { $0.id == taskID }), let project = model.projects.first(where: { $0.id == task.projectID }), let workspace = model.taskWorkspaces[task.id] else { return }
        let selectedBase = base, selectedTitle = title, selectedDescription = description, selectedEvidence = evidence
        run {
            guard let binding = try await model.store.githubTaskBinding(taskID: task.id) else { throw MochletError.message("This task has no GitHub issue binding.") }
            _ = try await publisher().preview(task: task, project: project, binding: binding, workspace: workspace,
                base: selectedBase, title: selectedTitle, body: selectedDescription, evidence: selectedEvidence)
        }
    }
    private func publish(_ value: Publication) {
        guard let project = model.projects.first(where: { $0.id == value.plan.binding.projectID }) else { return }
        run { try await publisher().publish(value, project: project) }
    }
    private func reconcile(_ value: Publication) { run { try await publisher().reconcile(value) } }
    private func discardPreview(_ value: Publication) {
        run { try await model.store.discardPublicationPreview(value.id) }
    }
}
