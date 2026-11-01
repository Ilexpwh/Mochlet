import SwiftUI
import SlimeCore

struct FileOperationsView: View {
    @Bindable var model: AppModel
    @State private var organizer: FileOrganizer?
    @State private var history: [FileMove] = []
    @State private var preview: [FileMove] = []
    @State private var message: String?
    @State private var busy = false
    @State private var showingPreview = false
    @State private var hasMore = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("File operations").font(.headline)
                Spacer()
                Button("Move selected files…") { chooseDestination() }.disabled(busy || model.isBusy || model.files.selected.isEmpty)
            }
            Text("Choose a destination, review every path, then apply. Existing files are never replaced. Undo is available while the moved file remains unchanged. Regular files only; cross-volume moves are not supported.").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
            ForEach(history) { move in
                HStack {
                    VStack(alignment: .leading) {
                        Text(URL(fileURLWithPath: move.source).lastPathComponent + " · " + move.state).font(.caption.weight(.semibold))
                        Text(move.destination).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(move.destination)
                        if let message = move.message { Text(message).font(.caption2).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if move.state == "applied" { Button("Undo") { perform([move], undo: true) }.disabled(busy || model.isBusy) }
                }
            }
            if hasMore { Button("Load older operations") { Task { await loadMore() } }.disabled(busy) }
        }.task {
            do { organizer = try FileOrganizer(folder: model.folder); try await reload() }
            catch { message = error.localizedDescription }
        }.sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review file moves").font(.title2.bold())
                Text("Moves are applied individually. If one fails, earlier successful moves remain in history with Undo.").font(.caption).foregroundStyle(.secondary)
                List(preview) { move in
                    VStack(alignment: .leading, spacing: 5) { Text("From: " + move.source); Text("To: " + move.destination).foregroundStyle(.secondary) }.font(.caption).textSelection(.enabled)
                }
                HStack { Button("Cancel") { showingPreview = false }; Spacer(); Button("Apply \(preview.count) moves") { showingPreview = false; perform(preview) }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 680, height: 420)
        }
    }
    private func reload() async throws { try await organizer?.reconcile(); history = try await organizer?.history() ?? []; hasMore = history.count == 50 }
    private func loadMore() async {
        busy = true; defer { busy = false }
        do { let page = try await organizer?.history(offset: history.count) ?? []; history.append(contentsOf: page); hasMore = page.count == 50 }
        catch { message = error.localizedDescription }
    }
    private func chooseDestination() {
        let presentingWindow = NSApp.keyWindow
        defer { presentingWindow?.makeKeyAndOrderFront(nil) }
        let paths = model.files.selected.map(\.path)
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.message = "Choose a destination folder. You will review all moves before applying."
        guard picker.runModal() == .OK, let destination = picker.url, let organizer else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { preview = try await organizer.preview(paths: paths, destination: destination); showingPreview = true }
            catch { message = error.localizedDescription }
        }
    }
    private func perform(_ moves: [FileMove], undo: Bool = false) {
        guard let organizer, !busy else { return }; busy = true; message = nil
        Task {
            defer { busy = false }
            var completed = 0
            do {
                for move in moves {
                    _ = try await organizer.apply(id: move.id, undo: undo); completed += 1
                    let oldPath = undo ? move.destination : move.source
                    for file in model.files.files.filter({ URL(fileURLWithPath: $0.path).standardizedFileURL == URL(fileURLWithPath: oldPath).standardizedFileURL }) { model.files.remove(file) }
                }
                message = "\(completed) \(undo ? "move undone" : "files moved"). Re-feed moved files to refresh their attachment paths. Saved memory keeps its original provenance."
            } catch { message = "\(completed) completed. " + error.localizedDescription }
            do { try await reload() } catch { message = error.localizedDescription }
        }
    }
}
