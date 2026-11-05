import AppKit
import SwiftUI

/// Settings → General → Permissions: every macOS permission with its state, Ask and Open buttons.
struct PermissionsSection: View {
    let app: AppCoordinator

    var body: some View {
        Section {
            ForEach(app.permissions.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Color(nsColor: row.status.colour)).frame(width: 8, height: 8).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.kind.name).font(.body)
                            Text(row.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if row.kind.canRequest, row.status != .granted {
                        Button("Ask") { app.permissions.request(row.kind) }.controlSize(.small)
                    }
                    Button("Open") { app.permissions.open(row.kind) }.controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text("Mochlet asks for each permission the first time a feature needs it; the system remembers the answer per build.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { app.permissions.refresh() }.controlSize(.small)
            }
        } header: {
            Text("Permissions")
        }
    }
}

/// Settings → General → Diagnostics: logs, storage, housekeeping.
struct DiagnosticsSection: View {
    let app: AppCoordinator
    @State private var folders: [Diagnostics.Folder] = []
    @State private var note: String?
    @State private var measuring = false

    var body: some View {
        Section {
            HStack {
                Button("Export logs (last 2 h)") { exportLogs() }
                Button("Open Logs folder") { reveal(Diagnostics.logsDir) }
                Button("Open ~/Mochlet") { reveal(Diagnostics.dataDir) }
                Button("Open support folder") { reveal(RelayInstaller.supportDir) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if folders.isEmpty {
                        Text(measuring ? "Measuring…" : "Storage: press Measure.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(folders) { f in
                        HStack {
                            Text(f.name).font(.caption)
                            Spacer()
                            Text(Diagnostics.format(f.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Show") { reveal(f.url) }.controlSize(.mini)
                        }
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Measure") { measure() }.controlSize(.small).disabled(measuring)
                    Button("Clean up now") { cleanUp() }.controlSize(.small)
                }
            }
            Text("Clean up removes exported logs older than 14 days, debug screenshots older than 7, processed inbox files older than 30 and cached pages older than 30. It runs daily by itself; nothing under ~/Mochlet is touched.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Diagnostics")
        }
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportLogs() {
        do {
            let url = try Diagnostics.exportLogs()
            note = "Exported \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            note = "Export failed: \(error.localizedDescription)"
        }
    }

    private func measure() {
        measuring = true
        Task.detached(priority: .utility) {
            let f = Diagnostics.folders()
            await MainActor.run { folders = f; measuring = false }
        }
    }

    private func cleanUp() {
        Task.detached(priority: .utility) {
            let s = Diagnostics.housekeeping()
            let f = Diagnostics.folders()
            await MainActor.run {
                note = s.files == 0 ? "Nothing to clean up." : "Removed \(s.files) files (\(Diagnostics.format(s.bytes)))."
                folders = f
            }
        }
    }
}
