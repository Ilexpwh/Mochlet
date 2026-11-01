import SwiftUI
import SlimeCore

@MainActor @Observable final class KnowledgeController {
    let vault: KnowledgeVault?
    var notes: [KnowledgeNote] = []
    var unavailableIDs: Set<String> = []
    let store: Store
    var validateConnected: ((KnowledgeNote) async throws -> Void)?
    var message: String?
    var answer: KnowledgeAnswer?
    var answerSources: [KnowledgeNote] = []
    var answering = false
    private var generation = UUID()
    init(folder: URL, store: Store) {
        self.store = store
        do { vault = try KnowledgeVault(directory: folder.appendingPathComponent("Knowledge", isDirectory: true), allows: { await store.allowsMemory($0) }) }
        catch { vault = nil; message = error.localizedDescription }
    }
    func refresh(query: String, scope: String, includePersonal: Bool) async {
        let token = UUID(); generation = token
        do {
            let result = try await vault?.search(query, scope: scope, includePersonal: includePersonal, includeUnavailable: true) ?? []
            var unavailable = Set<String>()
            for note in result where !(await store.allowsMemory(note)) { unavailable.insert(note.id) }
            guard generation == token, !Task.isCancelled else { return }; notes = result; unavailableIDs = unavailable
        } catch { if generation == token { message = error.localizedDescription } }
    }
    func save(_ note: KnowledgeNote) async -> Bool {
        guard let vault else { return false }
        do { try await vault.save(note, expectedRevision: (notes + answerSources).contains(where: { $0.id == note.id }) ? note.revision : nil); clearAnswer(); message = "Memory saved locally."; return true }
        catch { message = error.localizedDescription; return false }
    }
    func forget(_ note: KnowledgeNote) async {
        do { try await vault?.remove(note.id); notes.removeAll { $0.id == note.id }; clearAnswer(); message = "Memory forgotten. It will no longer be retrieved." }
        catch { message = error.localizedDescription }
    }
    func validate(_ sources: [KnowledgeNote]) async throws {
        guard let vault else { throw MochletError.message("Knowledge storage is unavailable.") }
        for source in sources {
            if source.connectionJSON != nil {
                guard let validateConnected else { throw MochletError.message("Connected memory validation is unavailable.") }
                try await validateConnected(source)
            }
        }
        // A later remote read can take seconds; recheck every earlier note only
        // after all remote work has settled.
        for source in sources {
            guard try await vault.isCurrent(source) else { throw MochletError.message("Memory changed or lost access. Retrieve it again.") }
        }
        try Task.checkCancellation()
    }
    func clearAnswer() { answer = nil; answerSources = [] }
    func ask(_ question: String, scope: String, includePersonal: Bool, speech: SpeechController) async {
        guard !answering, let vault else { return }
        answering = true; clearAnswer(); defer { answering = false }
        do {
            let sources = try await vault.search(question, scope: scope, includePersonal: includePersonal, limit: 6)
            guard !sources.isEmpty else { message = "No supporting memory was found in this scope. Try a more specific search or add a source."; return }
            let modelID = speech.analysisModel
            let catalog = try await speech.service.models(transcription: false)
            guard catalog.contains(where: { $0.id == modelID && $0.inputModalities.contains("text") && $0.outputModalities.contains("text") }) else {
                throw MochletError.message("Choose an available text analysis model in Speech & Models.")
            }
            try await validate(sources)
            let prompt = try KnowledgeAnswer.prompt(question: question, notes: sources)
            let text = try await speech.service.answer(prompt: prompt, model: modelID, key: speech.key())
            let result = try KnowledgeAnswer.decode(text, notes: sources)
            // Recheck authoritative files after inference; deleted or corrected evidence
            // must not be presented as a current answer from the old snapshot.
            try await validate(sources)
            guard !Task.isCancelled else { return }
            answer = result; answerSources = sources.filter { result.citations.contains($0.id) }; message = nil
        } catch { message = error.localizedDescription }
    }
    func reveal(_ note: KnowledgeNote) {
        Task { if let url = await vault?.url(note.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    }
}

struct KnowledgeView: View {
    @Bindable var model: AppModel
    @State private var scope = "personal"
    @State private var query = ""
    @State private var includePersonal = false
    @State private var editing: KnowledgeNote?
    @State private var forgetting: KnowledgeNote?
    @State private var retaining: KnowledgeNote?
    private var knowledge: KnowledgeController { model.knowledge }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Knowledge & Memory").font(.largeTitle.bold()); Spacer()
                Button("Import OKF…") { importDocuments() }
                Button("Add memory", systemImage: "plus") { editing = KnowledgeNote(scope: scope, title: "", body: "") }
            }
            HStack {
                Picker("Scope", selection: $scope) {
                    Text("Personal").tag("personal")
                    ForEach(model.projects) { Text($0.name).tag($0.id) }
                }.frame(maxWidth: 280).disabled(knowledge.answering)
                if scope != "personal" { Toggle("Include personal", isOn: $includePersonal).disabled(knowledge.answering) }
            }
            HStack {
                TextField("Search or ask about this knowledge", text: $query).textFieldStyle(.roundedBorder)
                Button(knowledge.answering ? "Answering…" : "Answer with sources") {
                    Task { await knowledge.ask(query, scope: scope, includePersonal: includePersonal, speech: model.speech) }
                }.disabled(query.isEmpty || knowledge.answering || !model.speech.hasKey || model.speech.analysisModel.isEmpty)
            }
            Text("Search stays local. Answer with sources sends your question and matching notes to the analysis model selected in Speech & Models. Sources are editable Markdown; project scopes stay separate.").font(.caption).foregroundStyle(.secondary)
            if let answer = knowledge.answer {
                VStack(alignment: .leading, spacing: 8) {
                    Label(answer.uncertain ? "Answer has uncertainty" : "Answer from your sources", systemImage: answer.uncertain ? "questionmark.circle" : "text.book.closed")
                    Text(answer.answer).textSelection(.enabled)
                    ForEach(knowledge.answerSources) { source in
                        Button("\(source.title) · revision \(source.revision.prefix(8))") { editing = source }.buttonStyle(.link)
                    }
                }.padding().background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
            }
            if let message = knowledge.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            ScrollView { LazyVStack(alignment: .leading, spacing: 12) { ForEach(knowledge.notes) { note in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(note.title).font(.headline); Spacer()
                        Button("Edit") { editing = note }.accessibilityLabel("Edit " + note.title)
                        Button("Show file") { knowledge.reveal(note) }.accessibilityLabel("Show file for " + note.title)
                        Button("Export…") { exportDocument(note) }.accessibilityLabel("Export " + note.title)
                        Button("Forget", role: .destructive) { forgetting = note }.accessibilityLabel("Forget " + note.title)
                    }
                    if note.connectionJSON != nil {
                        Text(knowledge.unavailableIDs.contains(note.id) ? "Excluded from AI context · connection, permission or source changed" : "Connected source · access is checked again before AI use")
                            .font(.caption).foregroundStyle(knowledge.unavailableIDs.contains(note.id) ? .orange : .secondary)
                        Button("Keep independent copy…") { retaining = note }.accessibilityLabel("Keep independent copy of " + note.title)
                    }
                    Text(note.body).lineLimit(3).foregroundStyle(.secondary)
                    Text("\(note.source) · \(Date(timeIntervalSince1970: note.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 7).accessibilityElement(children: .contain).buttonStyle(.borderless)
                Divider()
            } } }.overlay { if knowledge.notes.isEmpty { ContentUnavailableView("A little knowledge goes a long way", systemImage: "books.vertical", description: Text("Add preferences, project facts or source notes in the selected scope.")) } }
        }.padding(24)
            .task(id: "\(scope)|\(includePersonal)|\(query)") { await refresh() }
            .onChange(of: scope) { _, _ in knowledge.clearAnswer() }
            .onChange(of: includePersonal) { _, _ in knowledge.clearAnswer() }
            .sheet(item: $editing) { note in MemoryEditor(note: note) { updated in if await knowledge.save(updated) { editing = nil; await refresh(); return nil }; return knowledge.message } }
            .confirmationDialog("Keep an independent local copy?", isPresented: Binding(get: { retaining != nil }, set: { if !$0 { retaining = nil } })) {
                Button("Keep independent copy") { if let note = retaining { Task {
                    let copy = KnowledgeNote(scope: note.scope, title: note.title + " (local copy)", body: note.body,
                        source: note.source + " • explicitly retained as independent memory " + Date().ISO8601Format())
                    if await knowledge.save(copy) { retaining = nil; await refresh() }
                } } }
            } message: { Text("The new copy can be used in AI context without the original account or fresh source access. It keeps this snapshot and will not receive remote corrections. The original connected note is retained until you forget it.") }
            .confirmationDialog("Forget this memory?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
                Button("Forget memory", role: .destructive) { if let note = forgetting { Task { await knowledge.forget(note); forgetting = nil; await refresh() } } }
            } message: { Text("The local note and its search entry will be deleted. Existing agent conversations may still contain previously submitted context.") }
    }
    private func refresh() async { await knowledge.refresh(query: query, scope: scope, includePersonal: includePersonal) }
    private func importDocuments() {
        let window = NSApp.keyWindow; defer { window?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = "Import Markdown notes with scalar OKF type frontmatter into the selected scope. Unknown metadata is retained. Bundle relationships are not imported."
        guard panel.runModal() == .OK, let vault = knowledge.vault else { return }
        let urls = Array(panel.urls.prefix(100)); let selectedScope = scope
        Task {
            var failures: [String] = []; var count = 0
            for url in urls {
                do { _ = try await vault.importDocument(url, scope: selectedScope); count += 1 }
                catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
            }
            knowledge.clearAnswer(); knowledge.message = "Imported \(count) notes. " + failures.joined(separator: "\n"); await refresh()
        }
    }
    private func exportDocument(_ note: KnowledgeNote) {
        let window = NSApp.keyWindow; defer { window?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a folder for this portable Markdown note. Existing files will not be replaced."
        guard panel.runModal() == .OK, let directory = panel.url, let vault = knowledge.vault else { return }
        Task {
            do { let file = try await vault.exportDocument(note.id, directory: directory); knowledge.message = "Exported " + file.lastPathComponent }
            catch { knowledge.message = error.localizedDescription }
        }
    }
}

private struct MemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var note: KnowledgeNote
    @State private var saving = false
    @State private var error: String?
    let save: (KnowledgeNote) async -> String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit memory").font(.title2.bold())
            TextField("Title", text: $note.title)
            TextField("Source or provenance", text: $note.source)
            TextEditor(text: $note.body).font(.body).frame(minHeight: 240)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? "Saving…" : "Save") { saving = true; Task { error = await save(note); saving = false } }
                    .disabled(saving || note.title.isEmpty || note.body.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580)
    }
}
