import AppKit
import SwiftUI
import MochletCore

/// The knowledge card: ask, read the cited answer, file it; lint and reindex from the menu.
struct KnowledgeView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        let kb = app.knowledge!
        let store = app.notch
        let chrome: Double = 26 + 8 + 31 + 8 + (kb.answerText.isEmpty || kb.isAnswering ? 0 : 35)
        let answerMax = CGFloat(max(60, store.contentMaxHeight(for: .knowledge) - chrome))
        VStack(alignment: .leading, spacing: 8) {
            KnowledgeHeader(app: app)
            HStack(spacing: 6) {
                TextField("", text: Binding(get: { kb.query }, set: { kb.query = $0 }), prompt: fieldPrompt("Ask the knowledge base…"))
                    .focused($focused)
                    .onSubmit { kb.ask(kb.query) }
                    .islandField(focused: focused)
                if kb.isAnswering {
                    IslandButton("Stop", symbol: "stop.fill", role: .destructive) { kb.cancelAnswer() }
                } else {
                    IslandButton("Ask", symbol: "sparkles", role: .primary, keycap: "⏎") { kb.ask(kb.query) }
                }
            }
            FadeScroll(maxHeight: answerMax) {
                VStack(alignment: .leading, spacing: 8) {
                    if !kb.answerText.isEmpty {
                        MarkdownText(kb.answerText)
                            .font(IslandStyle.body)
                            .foregroundStyle(IslandStyle.ink)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                    } else if kb.isAnswering {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Looking through \(kb.counts.pages) pages…").font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2)
                        }
                    } else if let e = kb.lastError {
                        Text(e).font(IslandStyle.secondary).foregroundStyle(IslandStyle.error).fixedSize(horizontal: false, vertical: true)
                    } else {
                        KnowledgeIdleView(app: app)
                    }
                    if !kb.citations.isEmpty, !kb.answerText.isEmpty {
                        CitationRow(app: app, citations: kb.citations)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !kb.answerText.isEmpty, !kb.isAnswering {
                HStack(spacing: 8) {
                    if let f = kb.answerFiled {
                        IslandButton("Filed to \(f)", symbol: "checkmark.circle", role: .quiet) { kb.openPath(f) }
                    } else {
                        IslandButton("File this answer", symbol: "tray.and.arrow.down", role: .primary) { kb.fileAnswer() }
                        Text("saves a synthesis page with its sources").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .knowledge)
        .onAppear {
            focused = true
            app.window.focusInput()
        }
        .onChange(of: focused) { _, f in app.window.hold("knowledge-focus", f, scope: .view(.knowledge)) }
        .onDisappear { app.window.hold("knowledge-focus", false) }
    }
}

private struct KnowledgeHeader: View {
    let app: AppCoordinator

    var body: some View {
        let kb = app.knowledge!
        let title = kb.ready ? "\(kb.counts.pages) page\(kb.counts.pages == 1 ? "" : "s") · \(kb.counts.references) source\(kb.counts.references == 1 ? "" : "s")" : "Indexing…"
        CardHeader(symbol: "books.vertical", tint: IslandStyle.ink2, title: title, subtitle: kb.status, app: app) {
            if kb.chewing > 0 {
                ProgressView().controlSize(.mini).tint(.white)
            }
            IslandButton(kb.isLinting ? "Linting…" : "Lint", symbol: "stethoscope", role: .quiet) { kb.lint() }
            Menu {
                Button("Reindex") { kb.reindex() }
                Button("Rebuild index") { kb.reindex(force: true) }
                Divider()
                Button("Open folder in Finder") { kb.revealInFinder() }
                Button("Open log") { kb.openPath("log.md") }
                Button("Open schema") { kb.openPath("SCHEMA.md") }
                if let l = kb.lastLintPath { Button("Open last lint") { kb.openPath(l) } }
                Divider()
                Button("Knowledge settings…") { app.openSettings(tab: "knowledge") }
            } label: {
                MenuIconLabel(symbol: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Reindex, open the folder, settings")
        }
    }
}

private struct KnowledgeIdleView: View {
    let app: AppCoordinator

    var body: some View {
        let kb = app.knowledge!
        VStack(alignment: .leading, spacing: 6) {
            if let f = kb.lastFiled {
                IslandButton((f.existing ? "Already chewed: " : "Filed: ") + f.title, symbol: f.existing ? "checkmark.circle" : "tray.and.arrow.down", role: .quiet) {
                    kb.openPath(f.path)
                }
                if let n = f.note { Text(n).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).fixedSize(horizontal: false, vertical: true) }
            }
            if !kb.lastFindings.isEmpty {
                Text("Last lint: \(kb.lastFindings.count) finding\(kb.lastFindings.count == 1 ? "" : "s")")
                    .font(IslandStyle.secondaryStrong).foregroundStyle(IslandStyle.ink2)
                ForEach(kb.lastFindings.prefix(4)) { f in
                    Text("• \(f.kind.rawValue): \(f.detail)").font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(1)
                }
            } else if kb.lastFiled == nil {
                if kb.counts.pages == 0 {
                    EmptyState(symbol: "books.vertical", line: "Nothing filed yet.",
                               hint: "Drop a file, a link or some text on me and I chew it into \(IslandStyle.tilde(kb.root.path)).")
                } else {
                    Text("Ask a question; answers cite the pages they come from. Coding agents reach the same pages through MCP (Settings → Knowledge).")
                        .font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let n = kb.embeddingNote {
                Text(n).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Citation chips that wrap onto a second row instead of scrolling sideways.
private struct CitationRow: View {
    let app: AppCoordinator
    let citations: [Citation]

    /// "Title › heading" without repeating the page title when the heading path starts with it.
    private func chipTitle(_ c: Citation) -> String {
        var h = c.heading
        if h == c.title { h = "" } else if h.hasPrefix(c.title + " > ") { h = String(h.dropFirst(c.title.count + 3)) }
        var s = c.title + (h.isEmpty ? "" : " › \(h)")
        if let p = c.page { s += " · p.\(p)" }
        if let t = c.timestamp { s += " · \(AnswerComposer.timestampText(t))" }
        return s
    }

    var body: some View {
        let kb = app.knowledge!
        FlowLayout(spacing: 5, maxItemWidth: 260) {
            ForEach(citations) { c in
                ChipButton(text: "\(c.n)  \(chipTitle(c))", symbol: "doc.text") { kb.open(c) }
                    .help("\(c.path):\(c.lineStart)")
            }
        }
    }
}
