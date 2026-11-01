import SwiftUI
import SlimeCore

struct GitHubView: View {
    @Bindable var model: AppModel
    @State private var slug = ""
    @State private var showClosed = false
    var body: some View {
        @Bindable var github = model.github
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("GitHub").font(.largeTitle.bold()); Spacer(); if github.busy { ProgressView().controlSize(.small) } }
            Text("Connect a registered local project to its GitHub repository. Authentication uses your installed GitHub CLI.").foregroundStyle(.secondary)
            Picker("Project", selection: $model.selectedProjectID) {
                Text("Choose a project").tag("")
                ForEach(model.projects) { Text($0.name).tag($0.id) }
            }.disabled(github.busy)
            HStack {
                TextField("owner/repository", text: $slug)
                Button("Bind repository") { if let project = model.selectedProject { Task { await github.bind(project: project, slug: slug) } } }
                    .disabled(github.busy || model.selectedProject == nil || slug.isEmpty)
            }
            if let binding = github.binding {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(binding.repository.full_name).font(.headline)
                        Text("Account: \(binding.account.login)").font(.caption)
                        if let date = binding.syncedAt { Text("Last synced \(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(); Button("Sync issues") { Task { await github.sync() } }.disabled(github.busy)
                }
                Toggle("Show closed issues", isOn: $showClosed).toggleStyle(.checkbox)
                List(github.issues.filter { showClosed || $0.state == "open" }) { issue in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("#\(issue.number)").foregroundStyle(.secondary); Text(issue.title).font(.headline); Spacer(); Text(issue.state).font(.caption) }
                        Text(issue.body ?? "No description").lineLimit(3).foregroundStyle(.secondary)
                        HStack {
                            if let url = URL(string: issue.html_url), url.host == "github.com", url.scheme == "https" { Link("View issue", destination: url) }
                            Spacer()
                            Button("Prepare task") { Task { await github.prepare(issue, model: model) } }.disabled(github.busy || issue.state != "open")
                        }
                    }.padding(.vertical, 8)
                }
            } else {
                ContentUnavailableView("Connect a project", systemImage: "point.3.connected.trianglepath.dotted", description: Text("The local origin must match the selected repository. Sign in using gh auth login before connecting."))
            }
            if let message = github.message { Text(message).font(.callout).textSelection(.enabled) }
            DisclosureGroup("GitHub CLI") { TextField("Executable", text: $github.ghPath).textFieldStyle(.roundedBorder) }
            Text("Preparing an issue does not start coding. Review the destination and prompt in Companion, then Send. No issue comments, commits or pull requests are published by synchronization.").font(.caption).foregroundStyle(.secondary)
        }.padding(28)
            .task(id: model.selectedProjectID) { await github.load(projectID: model.selectedProjectID) }
    }
}
