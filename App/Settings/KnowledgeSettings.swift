import AppKit
import SwiftUI
import MochletCore
import MochletServices

struct KnowledgeSettingsView: View {
    let app: AppCoordinator
    @State private var copied = false

    var body: some View {
        @Bindable var s = app.settings
        let kb = app.knowledge!
        Form {
            Section("Folder") {
                HStack {
                    Text(kb.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { kb.revealInFinder() }
                    Button("Open schema") { kb.openPath("SCHEMA.md") }
                }
                HStack {
                    Text("\(kb.counts.pages) pages · \(kb.counts.chunks) passages · \(kb.counts.references) mirrored sources")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reindex") { kb.reindex() }
                    Button("Lint now") { kb.lint() }.disabled(kb.isLinting)
                }
                if let st = kb.status { Text(st).font(.caption).foregroundStyle(.secondary) }
                if let e = kb.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                Text("An OKF Markdown bundle you can open in Obsidian or any editor: reports under inbox/ and projects/, entities, concepts, filed answers under syntheses/, lint reports under meta/. Mochlet never edits a page you wrote or verified; it adds a “Proposed update” block instead. The schema in SCHEMA.md (copied to CLAUDE.md and AGENTS.md) tells coding agents the same rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search") {
                Toggle("Use on-device embeddings for search (Apple NLContextualEmbedding, Chinese and English)", isOn: Binding(get: { s.knowledgeEmbeddings }, set: { kb.setEmbeddings($0) }))
                HStack {
                    Text(embeddingStatus(kb)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download language assets") { kb.requestEmbeddingAssets() }.disabled(!s.knowledgeEmbeddings)
                }
                Text("Keyword search (BM25 over Chinese bigrams and English words) always works; vectors add meaning-based matches and are computed in the background from the index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Coding agents (MCP)") {
                HStack(spacing: 6) {
                    Circle().fill(kb.mcpPort != nil ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(kb.mcpPort.map { "Listening on 127.0.0.1:\($0) while Mochlet runs" } ?? (kb.mcpError ?? "Starting…"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Code").font(.caption).foregroundStyle(.secondary)
                    commandRow(kb.mcpCommand)
                    Text("Codex").font(.caption).foregroundStyle(.secondary)
                    commandRow(kb.codexMCPCommand)
                    Text("Cursor and other MCP clients: a stdio server with the command \(RelayInstaller.mcpURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) and no arguments.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Tools: find, search, read, list, tree, grep, add_resource, projects, signals_latest. The shim talks to the running app over a loopback port with a per-launch token (mcp.json in the support folder).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Keep history with git (one commit after each ingest, filed answer and lint; never pushes)", isOn: $s.knowledgeGit)
            }
            Section("Command line") {
                Text("The same engine without the app: \(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mochlet-cli").path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) reindex | find <query> | lint | ingest <file> | embed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func embeddingStatus(_ kb: KnowledgeController) -> String {
        let en = AppleContextualEmbedding.assetsAvailable(for: "The quick brown fox")
        let zh = AppleContextualEmbedding.assetsAvailable(for: "知识库")
        var parts = ["\(kb.counts.embedded) vectors"]
        if kb.pendingEmbeddings > 0 { parts.append("\(kb.pendingEmbeddings) pending") }
        parts.append("assets: English \(en ? "✓" : "–"), Chinese \(zh ? "✓" : "–")")
        if let n = kb.embeddingNote { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func commandRow(_ cmd: String) -> some View {
        HStack {
            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
        }
    }
}
