import SwiftUI
import SlimeCore

struct FilesView: View {
    @Bindable var model: AppModel
    @State private var preview: FileExtraction?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Feed Mochlet").font(.largeTitle.bold()); Spacer(); Button("Choose files or folder", systemImage: "plus") { model.files.choose() }.disabled(model.files.busy) }
            HStack {
                SlimeView(mood: model.files.busy ? .chewing : .idle, tint: model.tint).frame(width: 74, height: 74)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.files.busy ? "Chewing through your files…" : "Drop something to read").font(.headline)
                    Text("Text, PDF text and image OCR. Extraction stays local. Select up to six files for a coding turn or summary; each sends up to 6,000 characters.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.files.busy { ProgressView().controlSize(.small); Button("Cancel import") { model.files.cancel() } }
            }.padding().background(model.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button(model.files.analyzing ? "Summarizing…" : "Summarize selected") { Task { await model.files.analyze(speech: model.speech) } }
                    .disabled(model.files.selected.isEmpty || model.files.analyzing || !model.speech.hasKey || model.speech.analysisModel.isEmpty)
                Button(saving ? "Saving…" : "Save selected to memory") {
                    let notes = model.files.notes(scope: model.selectedProjectID.isEmpty ? "personal" : model.selectedProjectID)
                    saving = true; Task { for note in notes { _ = await model.knowledge.save(note) }; saving = false; model.files.message = model.knowledge.message }
                }.disabled(model.files.selected.isEmpty || saving)
                Text("Memory scope: \(model.selectedProject?.name ?? "Personal")").font(.caption).foregroundStyle(.secondary)
            }
            Text("Summaries send selected excerpts to your configured analysis model. Files remain in their original locations. Attachments are held for this app session; saving to memory retains extracted content.").font(.caption).foregroundStyle(.secondary)
            if let answer = model.files.answer { ScrollView { Text(answer.answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180).padding().background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)) }
            if let message = model.files.message { Text(message).font(.caption) }
            if !model.files.failures.isEmpty { DisclosureGroup("\(model.files.failures.count) skipped files or import limitations") { ScrollView { Text(model.files.failures.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100) } }
            ScrollView { LazyVStack(spacing: 8) { ForEach(model.files.files) { file in
                HStack(spacing: 12) {
                    Toggle("Select \(file.title)", isOn: Binding(get: { model.files.selectedIDs.contains(file.id) }, set: { _ in model.files.toggle(file) })).labelsHidden()
                    Image(systemName: file.kind == "Image OCR" ? "photo" : "doc.text").foregroundStyle(model.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.title).font(.headline)
                        Text("\(file.kind) · \(file.text.count) characters · \(file.warnings.isEmpty ? "Ready" : "Partial extraction")").font(.caption).foregroundStyle(.secondary)
                    }; Spacer()
                    Button("Preview") { preview = file }.accessibilityLabel("Preview " + file.title)
                    Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }.accessibilityLabel("Show " + file.title)
                    Button("Remove") { model.files.remove(file) }.accessibilityLabel("Detach " + file.title)
                }.padding(.vertical, 5).buttonStyle(.borderless).accessibilityElement(children: .contain)
            } } }
            DisclosureGroup("Organize files and undo") {
                ScrollView { FileOperationsView(model: model) }.frame(maxHeight: 220)
            }
        }.padding(24).overlay(FileDropSurface { model.files.ingest($0) })
            .sheet(item: $preview) { file in
                VStack(alignment: .leading, spacing: 12) {
                    Text(file.title).font(.title2.bold())
                    Text(file.path).font(.caption).textSelection(.enabled)
                    if !file.warnings.isEmpty { Text(file.warnings.joined(separator: "\n")).foregroundStyle(.orange) }
                    ScrollView { Text(file.text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Done") { preview = nil }.keyboardShortcut(.defaultAction)
                }.padding(24).frame(width: 680, height: 520)
            }
    }
}

// Layout adapted from Coucou ContextChip, b6a85f2. Copyright (c) 2026
// Louis Raillé. MIT; see LICENSES/Coucou-MIT.txt. Completion uses real data.
struct AttachmentChips: View {
    @Bindable var files: FileController
    let tint: Color
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(files.selected) { file in
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(file.title).font(.system(size: 11.5)).lineLimit(1)
                        Button { files.toggle(file) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("Detach \(file.title)")
                    }.padding(.horizontal, 10).padding(.vertical, 5).background(tint.opacity(0.13), in: Capsule())
                }
            }
        }.frame(maxHeight: 30)
    }
}
