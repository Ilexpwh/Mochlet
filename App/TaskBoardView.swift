import SwiftUI
import SlimeCore

struct TaskBoardView: View {
    @Bindable var model: AppModel
    var openCompanion: () -> Void
    @State private var projectID = ""
    @State private var query = ""
    @State private var priority = -1
    @State private var details: [String: TaskDetails] = [:]
    @State private var editing: WorkTask?
    @State private var creating = false
    @State private var title = ""
    @State private var message: String?
    private var visible: [WorkTask] {
        model.tasks.filter { task in
            (projectID.isEmpty || task.projectID == projectID) &&
            (query.isEmpty || task.title.localizedCaseInsensitiveContains(query)) &&
            (priority < 0 || (details[task.id]?.priority.rawValue ?? TaskPriority.normal.rawValue) == priority)
        }.sorted { a, b in
            let ap = details[a.id]?.priority.rawValue ?? 1, bp = details[b.id]?.priority.rawValue ?? 1
            if ap != bp { return ap > bp }
            let ad = details[a.id]?.dueAt ?? .infinity, bd = details[b.id]?.dueAt ?? .infinity
            if ad != bd { return ad < bd }
            return a.createdAt < b.createdAt
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Task board").font(.largeTitle.bold()); Spacer(); Button("New task", systemImage: "plus") { creating = true }.disabled(model.projects.isEmpty) }
            HStack {
                Picker("Project", selection: $projectID) { Text("All projects").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }
                TextField("Filter tasks", text: $query).textFieldStyle(.roundedBorder)
                Picker("Priority", selection: $priority) { Text("Any priority").tag(-1); ForEach(TaskPriority.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }
            }
            Text("Review successful runs before marking work complete. Saving or moving a task never starts an agent.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        let width = max(170, (geometry.size.width - 42) / 4)
                        lane("To do", icon: "tray", states: [.draft, .cancelled, .failed, .interrupted], width: width)
                        lane("In progress", icon: "waveform", states: [.queued, .running, .waiting], width: width)
                        lane("Review", icon: "eye", states: [.review], width: width)
                        lane("Done", icon: "checkmark.circle", states: [.completed], width: width)
                    }.padding(.bottom, 6)
                }
            }
        }.padding(24)
            .task { projectID = model.selectedProjectID; await refresh() }
            .sheet(item: $editing) { task in
                TaskDetailView(model: model, original: task, task: task, details: details[task.id] ?? .init(taskID: task.id), openCompanion: openCompanion) { await refresh() }
            }
            .sheet(isPresented: $creating) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("New task").font(.title2.bold())
                    TextField("Task title", text: $title)
                    Picker("Project", selection: $model.selectedProjectID) { Text("Choose a project").tag(""); ForEach(model.projects) { Text($0.name).tag($0.id) } }
                    Picker("Agent", selection: $model.defaultProvider) { ForEach(AgentProvider.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("Creates a draft. Open it in Companion when you are ready to give instructions.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Create draft") { Task {
                            do {
                                _ = try await model.store.createDraft(projectID: model.selectedProjectID, title: title, provider: model.defaultProvider)
                                title = ""; creating = false; await refresh()
                            } catch { message = error.localizedDescription; creating = false }
                        } }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.selectedProject == nil).keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 440)
            }
    }
    private func lane(_ title: String, icon: String, states: Set<WorkState>, width: CGFloat) -> some View {
        let tasks = visible.filter { states.contains($0.state) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack { Label(title, systemImage: icon).font(.headline); Spacer(); Text("\(tasks.count)").foregroundStyle(.secondary) }
            ScrollView { LazyVStack(spacing: 10) {
                ForEach(tasks) { task in
                    Button { editing = task } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(task.title).font(.headline).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                            Text(model.projects.first { $0.id == task.projectID }?.name ?? "Unavailable project").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(task.state.rawValue.capitalized)
                                Spacer()
                                Text(details[task.id]?.priority.title ?? "Normal")
                            }.font(.caption)
                            if let due = details[task.id]?.dueAt { Label(Date(timeIntervalSince1970: due).formatted(date: .abbreviated, time: .omitted), systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
                            if let dependencies = details[task.id]?.dependencies, !dependencies.isEmpty {
                                Text("\(dependencies.count) dependencies").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain).accessibilityLabel("Open task: \(task.title), \(task.state.rawValue)")
                        .accessibilityValue("Priority \(details[task.id]?.priority.title ?? "Normal"). " + (details[task.id]?.dueAt.map { "Due " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) } ?? "No due date."))
                }
                if tasks.isEmpty { Text("Nothing here yet").font(.caption).foregroundStyle(.secondary).padding(.vertical, 24) }
            } }
        }.padding(12).frame(width: width).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 18))
    }
    private func refresh() async {
        do { try await model.refresh(); details = try await model.store.taskDetails() }
        catch { message = error.localizedDescription }
    }
}

private struct TaskDetailView: View {
    @Bindable var model: AppModel
    let original: WorkTask
    @State var task: WorkTask
    @State var details: TaskDetails
    var openCompanion: () -> Void
    var saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var comment = ""
    @State private var comments: [TaskComment] = []
    @State private var attempts: [Run] = []
    private var active: Bool { [.queued, .running, .waiting].contains(original.state) }
    private var peers: [WorkTask] { model.tasks.filter { $0.projectID == task.projectID && $0.id != task.id }.sorted { $0.title < $1.title } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Task details").font(.title2.bold()); Spacer(); Text(original.state.rawValue.capitalized).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Group {
                        TextField("Title", text: $task.title)
                        HStack {
                            Picker("Project", selection: $task.projectID) { ForEach(model.projects) { Text($0.name).tag($0.id) } }
                            Picker("Agent", selection: $task.provider) { ForEach(AgentProvider.allCases, id: \.self) { Text($0.title).tag($0.rawValue) } }
                        }
                        HStack {
                            Picker("Status", selection: $task.state) { ForEach(active ? [original.state] : [.draft, .review, .completed, .cancelled, .failed, .interrupted], id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.disabled(active)
                            Picker("Priority", selection: $details.priority) { ForEach(TaskPriority.allCases, id: \.self) { Text($0.title).tag($0) } }
                        }
                        HStack {
                            Toggle("Due date", isOn: Binding(get: { details.dueAt != nil }, set: { details.dueAt = $0 ? Date().timeIntervalSince1970 : nil }))
                            if details.dueAt != nil { DatePicker("Due", selection: Binding(get: { Date(timeIntervalSince1970: details.dueAt ?? Date().timeIntervalSince1970) }, set: { details.dueAt = $0.timeIntervalSince1970 }), displayedComponents: .date).labelsHidden() }
                        }
                        TextField("Description / instructions", text: $details.description, axis: .vertical).lineLimit(3...8)
                        Picker("Parent task", selection: Binding(get: { details.parentID ?? "" }, set: { details.parentID = $0.isEmpty ? nil : $0 })) {
                            Text("None").tag(""); ForEach(peers) { Text($0.title).tag($0.id) }
                        }
                        DisclosureGroup("Dependencies (\(details.dependencies.count))") {
                            VStack(alignment: .leading) {
                                ForEach(peers) { peer in
                                    Toggle(peer.title + " · " + peer.state.rawValue, isOn: Binding(get: { details.dependencies.contains(peer.id) }, set: { if $0 { details.dependencies.insert(peer.id) } else { details.dependencies.remove(peer.id) } })).toggleStyle(.checkbox)
                                }
                            }.padding(.top, 8)
                        }
                    }.disabled(active || busy)
                    Text("Dependencies must be completed before starting. Project/agent changes are limited to unstarted, unbound drafts; existing sessions keep their destination.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    DisclosureGroup("Attempts (latest 100) · \(attempts.count)") {
                        ForEach(attempts) { run in
                            VStack(alignment: .leading) {
                                Text("\(Date(timeIntervalSince1970: run.startedAt).formatted()) · \(run.state.rawValue)").font(.caption.bold())
                                Text(run.prompt).textSelection(.enabled).lineLimit(8)
                            }.padding(.vertical, 5)
                        }
                    }
                    DisclosureGroup("Latest output") { Text(original.output.isEmpty ? "No agent output yet." : original.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Text("Comments (latest 200)").font(.headline)
                    ForEach(comments) { item in
                        VStack(alignment: .leading) { Text(item.body).textSelection(.enabled); Text(Date(timeIntervalSince1970: item.createdAt).formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack {
                        TextField("Add a local comment", text: $comment, axis: .vertical).lineLimit(1...4)
                        Button("Add comment") { Task {
                            do { try await model.store.addComment(taskID: task.id, body: comment); comment = ""; await load() }
                            catch { message = error.localizedDescription }
                        } }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.textFieldStyle(.roundedBorder).padding(.trailing, 5)
            }
            if let message { Text(message).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in Companion") {
                    guard model.draft.isEmpty, model.connectedDraft == nil, !model.preparingSubmission else { message = "Finish your current Companion draft first."; return }
                    model.selectedProjectID = original.projectID; model.selectedTaskID = original.id
                    dismiss(); openCompanion()
                }
                Spacer()
                Button("Save changes") { busy = true; Task {
                    do { try await model.store.editTask(expected: original, updated: task, details: details); await saved(); dismiss() }
                    catch { message = error.localizedDescription; busy = false }
                } }.disabled(active || busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 700).task { await load() }
    }
    private func load() async {
        do { comments = try await model.store.comments(taskID: original.id); attempts = try await model.store.attempts(taskID: original.id) }
        catch { message = error.localizedDescription }
    }
}
