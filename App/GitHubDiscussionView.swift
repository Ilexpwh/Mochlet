import SwiftUI
import SlimeCore

struct GitHubDiscussionRequest: Identifiable {
    let id = UUID()
    let issue: GitHubIssue
    let binding: GitHubBinding
}

struct GitHubDiscussionView: View {
    @Bindable var model: AppModel
    let request: GitHubDiscussionRequest
    @State private var snapshot: GitHubDiscussion?
    @State private var busy = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("#\(request.issue.number) · Discussion").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(request.binding.repository.full_name) · \(request.binding.account.login)").foregroundStyle(.secondary)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let snapshot { Text("Saved \(snapshot.fetchedAt.formatted()) · refresh to check for edits").font(.caption) }
                Spacer()
                Button("Refresh comments") { Task { await refresh() } }.disabled(busy)
            }
            if let message { Text(message).foregroundStyle(.red).font(.caption) }
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(snapshot.issue.title).font(.headline)
                        Text(snapshot.issue.body ?? "No description.").textSelection(.enabled)
                        Divider()
                        if snapshot.issue.discussion?.isEmpty == true { Text("No comments at this refresh.").foregroundStyle(.secondary) }
                        ForEach(snapshot.issue.discussion ?? []) { comment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(comment.user?.login ?? "Deleted author").font(.headline)
                                    Spacer(); Text(comment.updated_at).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(comment.body ?? "No text.").textSelection(.enabled)
                                if let url = URL(string: comment.html_url), url.scheme == "https", url.host == "github.com" { Link("Open comment", destination: url).font(.caption) }
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No saved discussion", systemImage: "text.bubble", description: Text("Refresh to read comments for this issue. No other issue discussions are downloaded."))
            }
            Text("Preparing a task fetches and verifies the discussion again. Comments are reference material and cannot change the selected project or grant tool access.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 700, height: 580)
        .task {
            do { snapshot = try await model.store.githubDiscussion(issueID: request.issue.id, binding: request.binding) }
            catch { message = error.localizedDescription }
            if snapshot == nil { await refresh() }
        }
    }
    private func refresh() async {
        guard !busy else { return }; busy = true; message = nil
        defer { busy = false }
        do {
            let fresh = try await GitHubClient(executable: model.github.ghPath).discussion(request.issue, binding: request.binding)
            try Task.checkCancellation()
            try await model.store.saveGitHubDiscussion(fresh)
            snapshot = fresh
        } catch { message = error.localizedDescription }
    }
}
