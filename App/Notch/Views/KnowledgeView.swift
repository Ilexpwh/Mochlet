import AppKit
import SwiftUI
import MochletCore

/// The knowledge card: ask, read the cited answer, file it; lint and reindex from the menu.
struct KnowledgeView: View {
    let app: AppCoordinator
    @FocusState private var focused: Bool

    var body: some View {
        let kb = app.knowledge!
        VStack(alignment: .leading, spacing: 6) {
            KnowledgeHeader(app: app)
            HStack(spacing: 6) {
                TextField("Ask the knowledge base…", text: Binding(get: { kb.query }, set: { kb.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                    .focused($focused)
                    .onSubmit { kb.ask(kb.query) }
                if kb.isAnswering {
                    IslandButton("Stop", symbol: "stop.fill") { kb.cancelAnswer() }
                } else {
                    IslandButton("Ask", symbol: "sparkles") { kb.ask(kb.query) }
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if !kb.answerText.isEmpty {
                        MarkdownText(kb.answerText)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                    } else if kb.isAnswering {
                        Text("Looking through \(kb.counts.pages) pages…")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                    } else if let e = kb.lastError {
                        Text(e).font(.system(size: 11, design: .rounded)).foregroundStyle(.orange.opacity(0.9))
                    } else {
                        KnowledgeIdleView(app: app)
                    }
                    if !kb.citations.isEmpty, !kb.answerText.isEmpty {
                        CitationRow(app: app, citations: kb.citations)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !kb.answerText.isEmpty, !kb.isAnswering {
                HStack(spacing: 6) {
                    if let f = kb.answerFiled {
                        Button { kb.openPath(f) } label: {
                            Label("Filed to \(f)", systemImage: "checkmark.circle").font(.system(size: 10.5, design: .rounded)).lineLimit(1)
                        }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
                    } else {
                        IslandButton("File this answer", symbol: "tray.and.arrow.down") { kb.fileAnswer() }
                        Text("saves a synthesis page with its sources").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            app.notch.measuredHeight = height(kb)
            focused = true
            app.window.focusInput()
        }
        .onChange(of: kb.answerText.isEmpty) { _, _ in app.notch.measuredHeight = height(kb) }
        .onChange(of: kb.citations.count) { _, _ in app.notch.measuredHeight = height(kb) }
        .onChange(of: focused) { _, f in app.window.hold("knowledge-focus", f, scope: .view(.knowledge)) }
        .onDisappear { app.window.hold("knowledge-focus", false) }
    }

    private func height(_ kb: KnowledgeController) -> Double {
        let base = NotchLayout.viewHeight(.knowledge)
        return kb.answerText.isEmpty ? base : 360
    }
}

private struct KnowledgeHeader: View {
    let app: AppCoordinator

    var body: some View {
        let kb = app.knowledge!
        HStack(spacing: 6) {
            Image(systemName: "books.vertical").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Text(kb.ready ? "\(kb.counts.pages) page\(kb.counts.pages == 1 ? "" : "s") · \(kb.counts.references) source\(kb.counts.references == 1 ? "" : "s")" : "Indexing…")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            if let s = kb.status {
                Text(s).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if kb.chewing > 0 {
                ProgressView().controlSize(.mini).tint(.white)
            }
            IslandButton(kb.isLinting ? "Linting…" : "Lint", symbol: "stethoscope") { kb.lint() }
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
                Image(systemName: "ellipsis.circle").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22, height: 22).foregroundStyle(.white.opacity(0.75))
            .help("Reindex, open the folder, settings")
        }
    }
}

private struct KnowledgeIdleView: View {
    let app: AppCoordinator

    var body: some View {
        let kb = app.knowledge!
        VStack(alignment: .leading, spacing: 5) {
            if let f = kb.lastFiled {
                Button { kb.openPath(f.path) } label: {
                    Label((f.existing ? "Already chewed: " : "Filed: ") + f.title, systemImage: f.existing ? "checkmark.circle" : "tray.and.arrow.down")
                        .font(.system(size: 11.5, design: .rounded)).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                if let n = f.note { Text(n).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.5)) }
            }
            if !kb.lastFindings.isEmpty {
                Text("Last lint: \(kb.lastFindings.count) finding\(kb.lastFindings.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.75))
                ForEach(kb.lastFindings.prefix(4)) { f in
                    Text("• \(f.kind.rawValue): \(f.detail)").font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            } else if kb.lastFiled == nil {
                Text(kb.counts.pages == 0
                     ? "Nothing filed yet. Drop a file, a link or some text on me and I'll chew it into \(kb.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."
                     : "Ask in Chinese or English; answers cite the pages they come from. Coding agents reach the same pages through MCP (Settings → Knowledge).")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            if let n = kb.embeddingNote {
                Text(n).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

private struct CitationRow: View {
    let app: AppCoordinator
    let citations: [Citation]

    /// "Title › heading" without repeating the page title when the heading path starts with it.
    private func chipTitle(_ c: Citation) -> String {
        var h = c.heading
        if h == c.title { h = "" } else if h.hasPrefix(c.title + " > ") { h = String(h.dropFirst(c.title.count + 3)) }
        return c.title + (h.isEmpty ? "" : " › \(h)")
    }

    var body: some View {
        let kb = app.knowledge!
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(citations) { c in
                    Button { kb.open(c) } label: {
                        HStack(spacing: 4) {
                            Text("\(c.n)").font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.18)))
                            Text(chipTitle(c)).font(.system(size: 10.5, design: .rounded)).lineLimit(1)
                            if let p = c.page { Text("p.\(p)").font(.system(size: 9.5, design: .rounded)).opacity(0.7) }
                            if let t = c.timestamp { Text(AnswerComposer.timestampText(t)).font(.system(size: 9.5, design: .monospaced)).opacity(0.7) }
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("\(c.path):\(c.lineStart)")
                }
            }
        }
    }
}
