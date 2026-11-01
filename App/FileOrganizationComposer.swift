import SwiftUI
import SlimeCore

struct FileOrganizationComposer: View {
    @Environment(\.dismiss) private var dismiss
    let files: [FileExtraction]
    let organizer: FileOrganizer
    let speech: SpeechController
    let prepared: ([FileMove]) -> Void
    @State private var destination: URL?
    @State private var instruction = ""
    @State private var useModel = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Organize loaded files").font(.title2.bold())
            Text("\(files.count) files · review paths before anything moves").font(.headline)
            HStack {
                Button("Choose destination…") { choose() }.disabled(busy)
                Text(destination?.path ?? "No destination selected").font(.caption).textSelection(.enabled)
            }
            Picker("Proposal", selection: $useModel) {
                Text("Group by file type · local").tag(false)
                Text("Follow my instructions · AI").tag(true)
            }.disabled(busy)
            if useModel {
                TextField("For example: put invoices under Finance and meeting notes under Meetings", text: $instruction, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(busy)
                Text("Sends filenames, format, extraction warnings and up to 1,000 excerpt characters per file to your selected analysis model. The model proposes paths; it cannot move files. A separate preview lists every move for approval.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Creates a local proposal for Documents, PDFs and Images subfolders. Nothing is sent to an AI provider.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Same-volume moves only. No overwrites, deletions or whole-directory moves. Missing subfolders are created only when you apply the reviewed plan. Undo restores unchanged files; created empty folders remain.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? "Preparing…" : "Preview organization") { prepare() }
                    .keyboardShortcut(.defaultAction).disabled(busy || destination == nil || (useModel && (instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !speech.hasKey || speech.analysisModel.isEmpty)))
            }
        }.padding(24).frame(width: 650).interactiveDismissDisabled(busy)
    }
    private func choose() {
        let presentingWindow = NSApp.keyWindow
        defer { presentingWindow?.makeKeyAndOrderFront(nil) }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the root folder for the reviewed organization."
        if panel.runModal() == .OK { destination = panel.url }
    }
    private func prepare() {
        guard let destination, !busy else { return }
        let requested = instruction; let wantsModel = useModel; let modelID = speech.analysisModel
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                var proposal = FileOrganizationProposal.byFileType(files)
                if wantsModel {
                    let catalog = try await speech.service.models(transcription: false)
                    guard catalog.contains(where: { $0.id == modelID && $0.inputModalities.contains("text") && $0.outputModalities.contains("text") }) else { throw MochletError.message("Choose an available text analysis model in Speech & Models.") }
                    let response = try await speech.service.answer(prompt: FileOrganizationProposal.prompt(instruction: requested, files: files), model: modelID, key: speech.key())
                    proposal = try FileOrganizationProposal.decode(response, files: files)
                }
                let moves = try await organizer.previewOrganization(proposal, files: files, destination: destination)
                prepared(moves)
            } catch { self.error = error.localizedDescription }
        }
    }
}
