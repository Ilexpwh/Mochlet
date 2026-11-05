import AppKit
import SwiftUI
import MochletCore

/// The ingest card: what the slime is chewing, the project question, and the result.
struct IngestView: View {
    let app: AppCoordinator

    var body: some View {
        let ing = app.ingest!
        VStack(alignment: .leading, spacing: 7) {
            IngestHeader(app: app)
            if let q = ing.question, let job = ing.job(q.jobID) {
                ProjectPickView(app: app, job: job, question: q.question, deadline: q.deadline)
            } else if let job = ing.current {
                JobView(app: app, job: job)
            } else {
                Text("Drop a file, a link or some text on me and I'll chew it into the knowledge base.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct IngestHeader: View {
    let app: AppCoordinator

    var body: some View {
        let ing = app.ingest!
        HStack(spacing: 6) {
            Image(systemName: ing.active.isEmpty ? "tray.full" : "fork.knife").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Text(ing.active.isEmpty ? (ing.current?.stage == .failed ? "Couldn't chew that" : "Chewed") : "Chewing…")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            if ing.active.count > 1 {
                Text("\(ing.active.count - 1) more in the queue").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            IslandButton("Knowledge", symbol: "books.vertical") { app.openKnowledge() }
        }
    }
}

private struct JobView: View {
    let app: AppCoordinator
    let job: IngestController.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Text(job.title ?? job.label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 0)
                if let p = job.project, let name = app.projects.file.project(slug: p)?.name {
                    Chip(text: name, symbol: "folder")
                } else if job.stage == .done {
                    Chip(text: "Inbox", symbol: "tray")
                }
            }
            if job.isActive {
                ProgressView(value: job.stage.progressStart + job.progress * 0.1)
                    .progressViewStyle(.linear).tint(.white.opacity(0.85)).frame(height: 4)
                Text(stageLine).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            } else if job.stage == .failed {
                Text(job.error ?? "failed").font(.system(size: 11, design: .rounded)).foregroundStyle(.orange.opacity(0.95)).lineLimit(2)
                if let f = job.filed { Text("Kept as \(f.path)").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                HStack(spacing: 6) {
                    IslandButton("Try again", symbol: "arrow.clockwise") { app.ingest.retry(job.id) }
                    if let f = job.filed { IslandButton("Open", symbol: "doc.text") { app.knowledge.openPath(f.path) } }
                    IslandButton("Log", symbol: "list.bullet.rectangle") { app.knowledge.openPath("log.md") }
                }
            } else {
                if let s = job.summary, !s.isEmpty {
                    Text(s).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                }
                if let i = job.integration {
                    Text("Wiki: \(i)").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                } else if let w = job.warnings.first {
                    Text(w).font(.system(size: 10, design: .rounded)).foregroundStyle(.orange.opacity(0.8)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let f = job.filed {
                        IslandButton("Open", symbol: "doc.text") { app.knowledge.openPath(f.path) }
                        IslandButton("Ask", symbol: "sparkles") { app.openKnowledge(question: "What does \"\(OneLine.collapse(f.title, limit: 60))\" say?") }
                        if !app.projects.projects.isEmpty {
                            Menu {
                                Button("Inbox") { Task { await app.ingest.move(job.id, toProject: nil) } }
                                ForEach(app.projects.projects) { p in
                                    Button(p.name) { Task { await app.ingest.move(job.id, toProject: p.slug) } }
                                }
                            } label: {
                                Label("Move", systemImage: "folder.badge.gearshape").font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.white.opacity(0.9))
                        }
                        if f.existing { IslandButton("Re-chew", symbol: "arrow.clockwise") { app.ingest.retry(job.id) } }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Which project is “\(OneLine.collapse(job.title ?? job.label, limit: 50))” for?")
                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 6) {
                ForEach(Array(question.options.prefix(4).enumerated()), id: \.offset) { _, o in
                    IslandButton(o.name + (o.confidence > 0 ? " \(Int((o.confidence * 100).rounded()))%" : ""), symbol: o.slug == nil ? "tray" : "folder") {
                        app.ingest.choose(o.slug)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded()))
                let name = question.suggested.flatMap { s in app.projects.file.project(slug: s)?.name } ?? "Inbox"
                Text("\(name) in \(left) s unless you pick one").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct Chip: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.12))).foregroundStyle(.white.opacity(0.85))
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
