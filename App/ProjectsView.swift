import SwiftUI
import SlimeCore

struct ProjectsView: View {
    @Bindable var model: AppModel
    var openProject: () -> Void
    @State private var editing: Project?
    @State private var reference = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Projects").font(.largeTitle.bold()); Spacer(); Button("Add folder", systemImage: "plus", action: model.addProject) }
            Text("Every task keeps its project, working folder and exact agent session.").foregroundStyle(.secondary)
            HStack {
                TextField("Find by exact project name or alias", text: $reference)
                Button("Use project") {
                    do { model.selectedProjectID = try ProjectResolver.resolve(reference, projects: model.projects).id; openProject() }
                    catch { model.report(error) }
                }.disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.projects.isEmpty { ContentUnavailableView("Bring your first project", systemImage: "folder.badge.plus", description: Text("Choose a local folder to give Mochlet a place to work.")) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(model.projects) { project in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(project.name).font(.headline)
                        Text(project.root).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if !project.aliases.isEmpty { Text("Aliases: " + project.aliases).font(.caption) }
                        if !(project.instructions ?? "").isEmpty { Label("Project instructions enabled", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Settings") { editing = project }.accessibilityLabel("Settings for " + project.name)
                    Button("Open") { model.selectedProjectID = project.id; openProject() }.accessibilityLabel("Open " + project.name)
                }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12)).buttonStyle(.borderless)
            } } }
        }.padding(28)
            .sheet(item: $editing) { ProjectEditor(model: model, original: $0) }
    }
}

private struct ProjectEditor: View {
    @Bindable var model: AppModel
    let original: Project
    @Environment(\.dismiss) private var dismiss
    @State private var edited: Project
    @State private var saving = false
    @State private var message: String?
    init(model: AppModel, original: Project) { self.model = model; self.original = original; _edited = State(initialValue: original) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project settings").font(.title2.bold())
            Form {
                TextField("Name", text: $edited.name)
                TextField("Aliases, separated by commas", text: $edited.aliases)
                Text("Aliases are exact matches. If more than one project matches, Mochlet asks you to choose; it never guesses.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Working folder") { Text(edited.root).textSelection(.enabled).lineLimit(3) }
                Button("Choose another folder…", action: chooseFolder)
                Text("A folder can change only before the project has tasks or a GitHub binding. Existing sessions keep their original destination.").font(.caption).foregroundStyle(.secondary)
                Text("Project instructions").font(.headline)
                TextEditor(text: Binding(get: { edited.instructions ?? "" }, set: { edited.instructions = $0 })).frame(minHeight: 140).border(.quaternary)
                    .accessibilityLabel("Project instructions")
                Text("Saved preferences accompany each submitted coding request for this project. They are sent to the selected agent, appear in the run's prompt history, and do not override your current request. Do not put credentials here.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("Save project") { save() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 620, height: 650).disabled(saving)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the working folder. Existing sessions cannot be moved."
        if panel.runModal() == .OK, let url = panel.url { edited.root = url.path }
    }
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { _ = try await model.store.editProject(edited, expected: original); try await model.refresh(); dismiss() }
            catch { message = error.localizedDescription }
        }
    }
}
