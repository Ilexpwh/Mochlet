import AppKit
import SwiftUI
import MochletCore

/// The ingest card: what the slime is chewing, the project question, and the result.
struct IngestView: View {
    let app: AppCoordinator

    var body: some View {
        let ing = app.ingest!
        VStack(alignment: .leading, spacing: 8) {
            IngestHeader(app: app)
            if let q = ing.question, let job = ing.job(q.jobID) {
                ProjectPickView(app: app, job: job, question: q.question, deadline: q.deadline)
            } else if let job = ing.current {
                JobView(app: app, job: job)
            } else {
                EmptyState(symbol: "arrow.down.doc", line: "Drop something on me.", hint: "A file, a link or some text: I chew it into the knowledge base.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .ingest)
    }
}

private struct IngestHeader: View {
    let app: AppCoordinator

    var body: some View {
        let ing = app.ingest!
        let failed = ing.current?.stage == .failed
        let title = ing.active.isEmpty ? (failed ? "Couldn't chew that" : (ing.current == nil ? "Chew" : "Chewed")) : "Chewing…"
        CardHeader(symbol: ing.active.isEmpty ? "tray.full" : "fork.knife",
                   tint: ing.active.isEmpty ? (failed ? IslandStyle.error : IslandStyle.done) : IslandStyle.working,
                   title: title, subtitle: ing.active.count > 1 ? "\(ing.active.count - 1) more in the queue" : nil, app: app) {
            IslandButton("Knowledge", symbol: "books.vertical", role: .quiet) { app.openKnowledge() }
        }
    }
}

private struct JobView: View {
    let app: AppCoordinator
    let job: IngestController.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(IslandStyle.ink2)
                Text(job.title ?? job.label).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let p = job.project, let name = app.projects.file.project(slug: p)?.name {
                    Chip(text: name, symbol: "folder")
                } else if job.stage == .done {
                    Chip(text: "Inbox", symbol: "tray")
                }
            }
            if job.isActive {
                ProgressBar(value: job.stage.progressStart + job.progress * 0.1, tint: IslandStyle.working)
                Text(stageLine).font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).lineLimit(1)
            } else if job.stage == .failed {
                Text(job.error ?? "failed").font(IslandStyle.body).foregroundStyle(IslandStyle.error).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let f = job.filed { Text("Kept as \(f.path)").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(1).truncationMode(.middle) }
                HStack(spacing: 6) {
                    IslandButton("Try again", symbol: "arrow.clockwise", role: .primary) { app.ingest.retry(job.id) }
                    if let f = job.filed { IslandButton("Open", symbol: "doc.text") { app.knowledge.openPath(f.path); app.window.send(.acknowledged()) } }
                    IslandButton("Log", symbol: "list.bullet.rectangle", role: .quiet) { app.knowledge.openPath("log.md"); app.window.send(.acknowledged()) }
                }
            } else {
                if let s = job.summary, !s.isEmpty {
                    Text(s).font(IslandStyle.body).foregroundStyle(IslandStyle.ink2).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let i = job.integration {
                    Text("Wiki: \(i)").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineLimit(1)
                } else if let w = job.warnings.first {
                    Text(w).font(IslandStyle.caption).foregroundStyle(IslandStyle.attention.opacity(0.9)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let f = job.filed {
                        IslandButton("Open", symbol: "doc.text", role: .primary, keycap: "⏎") { app.knowledge.openPath(f.path); app.window.send(.acknowledged()) }
                        IslandButton("Ask", symbol: "sparkles") { app.openKnowledge(question: "What does \"\(OneLine.collapse(f.title, limit: 60))\" say?") }
                        if !app.projects.projects.isEmpty {
                            Menu {
                                Button("Inbox") { Task { await app.ingest.move(job.id, toProject: nil) } }
                                ForEach(app.projects.projects) { p in
                                    Button(p.name) { Task { await app.ingest.move(job.id, toProject: p.slug) } }
                                }
                            } label: {
                                MenuLabel(title: "Move", symbol: "folder.badge.gearshape")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        if f.existing { IslandButton("Re-chew", symbol: "arrow.clockwise", role: .quiet) { app.ingest.retry(job.id) } }
                    }
                }
            }
        }
    }

    private var symbol: String {
        switch job.input {
        case .file: return "doc"
        case .url: return "link"
        case .text: return "text.alignleft"
        case .window: return "macwindow"
        }
    }

    private var stageLine: String {
        var s = job.stage.label
        if job.progress > 0, job.stage != .analysing { s += " \(Int((job.progress * 100).rounded()))%" }
        if let d = job.detail { s += " · \(d)" }
        return s
    }
}

private struct ProjectPickView: View {
    let app: AppCoordinator
    let job: IngestController.Job
    let question: ProjectQuestion
    let deadline: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which project is “\(OneLine.collapse(job.title ?? job.label, limit: 50))” for?")
                .font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(Array(question.options.prefix(6).enumerated()), id: \.offset) { i, o in
                    ChipButton(text: o.name + (o.confidence > 0 ? " \(Int((o.confidence * 100).rounded()))%" : ""),
                               symbol: o.slug == nil ? "tray" : "folder", selected: i == 0 && o.slug == question.suggested) {
                        app.ingest.choose(o.slug)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded()))
                let name = question.suggested.flatMap { s in app.projects.file.project(slug: s)?.name } ?? "Inbox"
                Text("\(name) in \(left) s unless you pick one").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).monospacedDigit()
            }
        }
    }
}

/// Small progress ring in the compact strip while the slime chews.
struct ChewRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}
