import AppKit
import SwiftUI
import MochletCore

/// The meeting card: the ask ("Capture this call?"), the live transcript while recording, the stages
/// while the notes are written, the speaker map when they are ready, and the recent meetings otherwise.
struct MeetingView: View {
    let app: AppCoordinator

    var body: some View {
        let m = app.meetings!
        VStack(alignment: .leading, spacing: 8) {
            switch m.state {
            case .asking: MeetingAskView(app: app)
            case .starting: MeetingStartingView(app: app)
            case .recording: MeetingLiveView(app: app)
            case .processing: MeetingProcessingView(app: app)
            case .review: MeetingReviewView(app: app)
            case .failed: MeetingFailedView(app: app)
            case .idle: MeetingIdleView(app: app)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .meetingLive)
    }
}

struct MeetingAskView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        let d = m.detection
        CardHeader(symbol: "waveform.badge.mic", tint: IslandStyle.working, title: "Capture this meeting?", subtitle: d?.appName, app: app)
        if let t = d?.title, !t.isEmpty, t != d?.appName {
            Text(t).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2).lineLimit(1)
        }
        Text("Your microphone and what the Mac plays are transcribed on this Mac; the notes land in the knowledge base.")
            .font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
            IslandButton("Capture", symbol: "record.circle", role: .primary, keycap: "⏎") { m.accept() }
            IslandButton("Not now", symbol: "clock") { m.dismissAsk(snooze: true) }
            IslandButton("Always", symbol: "checkmark.circle") { m.always() }
            Spacer(minLength: 0)
            IslandButton("Never for \(d?.appName ?? "it")", symbol: "nosign", role: .quiet) { m.never() }
        }
    }
}

struct MeetingLiveView: View {
    let app: AppCoordinator
    @State private var note = ""
    var body: some View {
        let m = app.meetings!
        HStack(spacing: 8) {
            RecDot()
            Text(m.current?.title ?? "Meeting").font(IslandStyle.title).foregroundStyle(IslandStyle.ink).lineLimit(1).layoutPriority(1)
            Text(MeetingTime.stamp(m.elapsed, millis: false)).font(IslandStyle.mono).foregroundStyle(IslandStyle.ink2).monospacedDigit()
            Spacer(minLength: 8)
            Meter(label: "mic", level: m.micLevel)
            Meter(label: "mac", level: m.systemLevel, muted: m.systemAudioError != nil)
            CardTools(app: app)
        }
        .frame(minHeight: 26)
        VStack(alignment: .leading, spacing: 4) {
            if m.liveLines.isEmpty {
                Text("Listening… the words show here as they come.").font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3)
            }
            ForEach(m.liveLines.suffix(3)) { l in
                HStack(alignment: .top, spacing: 6) {
                    Text(l.speaker == "me" ? "Me" : "Them").font(IslandStyle.captionStrong)
                        .foregroundStyle(l.speaker == "me" ? IslandStyle.working : IslandStyle.attention)
                        .frame(width: 36, alignment: .leading).padding(.top, 1)
                    Text(l.text).font(IslandStyle.body).foregroundStyle(IslandStyle.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            IslandButton("Stop", symbol: "stop.fill", role: .destructive) { m.stop() }
            IslandButton("Mark", symbol: "bookmark") { m.mark() }
            TextField("", text: $note, prompt: fieldPrompt("Note at this moment…"))
                .onSubmit { m.mark(note); note = "" }
                .islandField(size: 12)
        }
    }
}

struct MeetingStartingView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        CardHeader(symbol: "mic", tint: IslandStyle.working, title: "Meeting notes", app: app)
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text(m.stage.isEmpty ? "Starting…" : m.stage.prefix(1).uppercased() + m.stage.dropFirst() + "…")
                .font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2)
        }
        Text("The first time, macOS asks for the microphone and for System Audio Recording; you keep hearing the call.")
            .font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        IslandButton("Cancel", symbol: "xmark", role: .quiet) { m.cancelStart() }
    }
}

struct MeetingProcessingView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        CardHeader(symbol: "waveform", tint: IslandStyle.working, title: "Writing the notes", subtitle: m.current?.title, app: app)
        ProgressBar(value: m.progress, tint: IslandStyle.working)
        Text(m.stage).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink3).lineLimit(1)
    }
}

struct MeetingReviewView: View {
    let app: AppCoordinator
    @State private var renaming: String?
    @State private var name = ""
    @State private var expanded = false
    var body: some View {
        let m = app.meetings!
        if let f = m.last {
            CardHeader(symbol: "checkmark.circle", tint: IslandStyle.done, title: f.meta.title,
                       meta: "\(MeetingTime.duration(f.meta.durationS)) · \(f.lines.count) lines", app: app)
            if let o = f.summary?.overview, !o.isEmpty {
                Text(o).islandBody().lineLimit(expanded ? nil : 3)
                if o.count > 220 {
                    ChipButton(text: expanded ? "less" : "more", symbol: expanded ? "chevron.up" : "chevron.down") { expanded.toggle() }
                }
            } else if !m.stage.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(m.stage).font(IslandStyle.secondary).foregroundStyle(IslandStyle.ink2)
                }
            } else if let e = m.summaryError {
                HStack(spacing: 6) {
                    Text("No summary: \(e)").font(IslandStyle.secondary).foregroundStyle(IslandStyle.attention).lineLimit(1)
                    IslandButton("Retry", symbol: "arrow.clockwise", role: .quiet) { m.retrySummary() }
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text("Speakers").font(IslandStyle.captionStrong).foregroundStyle(IslandStyle.ink3).padding(.top, 5)
                FlowLayout(spacing: 5) {
                    ForEach(f.meta.speakers) { s in
                        let suggestion = f.summary?.participants.first { $0.speakerID == s.id }?.suggestedName
                        if renaming == s.id {
                            TextField("", text: $name, prompt: fieldPrompt(s.name))
                                .onSubmit { m.rename(s.id, to: name); renaming = nil }
                                .islandField(focused: true, size: 11.5)
                                .frame(width: 130)
                        } else if let suggestion, suggestion != s.name {
                            ChipButton(text: "\(s.name) → \(suggestion)?", symbol: "person.fill.questionmark") { m.acceptSuggestedName(s.id) }
                        } else {
                            ChipButton(text: s.name, symbol: s.isMe ? "person.fill" : "person") { renaming = s.id; name = s.name }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                IslandButton("Summary", symbol: "doc.text", role: .primary, keycap: "⏎") { m.openSummary(); app.window.send(.acknowledged()) }
                IslandButton("Transcript", symbol: "text.quote") { m.openTranscript(); app.window.send(.acknowledged()) }
                IslandButton("Ask", symbol: "questionmark.bubble") { app.openKnowledge(question: "What was decided in the meeting \"\(f.meta.title)\"?") }
                IslandButton("Folder", symbol: "folder") { m.openFolder(); app.window.send(.acknowledged()) }
                Spacer(minLength: 0)
                IslandButton("Done", symbol: "checkmark", role: .quiet) { m.dismiss() }
            }
        }
    }
}

struct MeetingFailedView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        CardHeader(symbol: "exclamationmark.triangle", tint: IslandStyle.error, title: "Couldn't write the notes", app: app)
        Text(m.error ?? "").font(IslandStyle.body).foregroundStyle(IslandStyle.ink2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
            IslandButton("Retry", symbol: "arrow.clockwise", role: .primary) { m.retry() }
            IslandButton("Folder", symbol: "folder") { m.openFolder(); app.window.send(.acknowledged()) }
            Spacer(minLength: 0)
            IslandButton("Dismiss", symbol: "xmark", role: .quiet) { m.dismiss() }
        }
    }
}

struct MeetingIdleView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        CardHeader(symbol: "waveform", tint: IslandStyle.working, title: "Meeting notes",
                   subtitle: m.recent.isEmpty ? nil : "\(m.recent.count) recent", app: app) {
            IslandButton("Start", symbol: "record.circle", role: .primary) { m.toggle() }
            IslandButton("Folder", symbol: "folder", role: .quiet) { m.openFolder(); app.window.send(.acknowledged()) }
        }
        if m.recent.isEmpty {
            EmptyState(symbol: "person.2.wave.2", line: "Triple-click me in a call, or I'll ask when I notice one.",
                       hint: "I record both sides, transcribe on this Mac and file the notes in the knowledge base.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(m.recent.prefix(4), id: \.meta.id) { f in
                    HStack(spacing: 4) {
                        ListRow(action: { m.openSummary(f); app.window.send(.acknowledged()) }) {
                            HStack(spacing: 8) {
                                Text(f.meta.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(IslandStyle.caption).foregroundStyle(IslandStyle.ink3).monospacedDigit().frame(width: 112, alignment: .leading)
                                Text(f.meta.title).font(IslandStyle.bodyStrong).foregroundStyle(IslandStyle.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        IconButton("text.quote", help: "Transcript", size: 24) { m.openTranscript(f); app.window.send(.acknowledged()) }
                    }
                }
            }
        }
    }
}

struct RecDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle().fill(Color.red.opacity(on ? 1 : 0.35)).frame(width: 8, height: 8)
        }
    }
}

struct Meter: View {
    var label: String
    var level: Float
    var muted = false
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(IslandStyle.captionStrong).foregroundStyle(IslandStyle.ink3)
            RoundedRectangle(cornerRadius: 2).fill(IslandStyle.fill).frame(width: 36, height: 5)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(muted ? IslandStyle.attention.opacity(0.7) : IslandStyle.ink2)
                        .frame(width: muted ? 36 : CGFloat(min(1, level * 6)) * 36)
                }
            if muted { Image(systemName: "speaker.slash").font(.system(size: 8)).foregroundStyle(IslandStyle.attention) }
        }
        .accessibilityLabel(muted ? "\(label) muted" : "\(label) level")
    }
}

/// The compact strip's REC pill while a meeting records.
struct RecPill: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        HStack(spacing: 4) {
            RecDot()
            Text(MeetingTime.stamp(m.elapsed, millis: false).dropFirst(3)).font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.red.opacity(0.25)))
    }
}
