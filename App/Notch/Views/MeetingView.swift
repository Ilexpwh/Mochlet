import AppKit
import SwiftUI
import MochletCore

/// The meeting card: the ask ("Capture this call?"), the live transcript while recording, the stages
/// while the notes are written, the speaker map when they are ready, and the recent meetings otherwise.
struct MeetingView: View {
    let app: AppCoordinator

    var body: some View {
        let m = app.meetings!
        VStack(alignment: .leading, spacing: 7) {
            switch m.state {
            case .asking: MeetingAskView(app: app)
            case .starting: MeetingStartingView(app: app)
            case .recording: MeetingLiveView(app: app)
            case .processing: MeetingProcessingView(app: app)
            case .review: MeetingReviewView(app: app)
            case .failed: MeetingFailedView(app: app)
            case .idle: MeetingIdleView(app: app)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MeetingCardTitle: View {
    var symbol: String
    var text: String
    var tint: Color = .white
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint.opacity(0.9))
            Text(text).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
    }
}

struct MeetingAskView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        let d = m.detection
        MeetingCardTitle(symbol: "waveform.badge.mic", text: "Capture this meeting in \(d?.appName ?? "this app")?")
        if let t = d?.title, !t.isEmpty, t != d?.appName {
            Text(t).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
        Text("Your microphone and what the Mac plays are transcribed on this Mac; the notes land in the knowledge base.")
            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
        HStack(spacing: 6) {
            IslandButton("Capture", symbol: "record.circle") { m.accept() }
            IslandButton("Not now", symbol: "xmark") { m.dismissAsk(snooze: true) }
            IslandButton("Always", symbol: "checkmark.circle") { m.always() }
            IslandButton("Never for \(d?.appName ?? "it")", symbol: "nosign") { m.never() }
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
            Text(m.current?.title ?? "Meeting").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
            Text(MeetingTime.stamp(m.elapsed, millis: false)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            Meter(label: "mic", level: m.micLevel)
            Meter(label: "mac", level: m.systemLevel, muted: m.systemAudioError != nil)
        }
        VStack(alignment: .leading, spacing: 3) {
            if m.liveLines.isEmpty {
                Text("Listening… the words show here as they come.").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(m.liveLines.suffix(3)) { l in
                HStack(alignment: .top, spacing: 5) {
                    Text(l.speaker == "me" ? "Me" : "Them").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(l.speaker == "me" ? Color(red: 0.5, green: 0.83, blue: 1) : .orange.opacity(0.9)).frame(width: 34, alignment: .leading)
                    Text(l.text).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 6) {
            IslandButton("Stop", symbol: "stop.circle") { m.stop() }
            IslandButton("Mark", symbol: "bookmark") { m.mark() }
            TextField("Note at this moment…", text: $note)
                .textFieldStyle(.plain).font(.system(size: 11, design: .rounded)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                .onSubmit { m.mark(note); note = "" }
        }
    }
}

struct MeetingStartingView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        MeetingCardTitle(symbol: "mic", text: "Meeting notes")
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(.white)
            Text(m.stage.isEmpty ? "Starting…" : m.stage.prefix(1).uppercased() + m.stage.dropFirst() + "…")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7))
        }
        Text("The first time, macOS asks for the microphone and for System Audio Recording; you keep hearing the call.")
            .font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
        IslandButton("Cancel", symbol: "xmark") { m.cancelStart() }
    }
}

struct MeetingProcessingView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        MeetingCardTitle(symbol: "waveform", text: "Writing the notes of \(m.current?.title ?? "the meeting")…")
        ProgressView(value: m.progress).tint(.white.opacity(0.8))
        Text(m.stage).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.55))
    }
}

struct MeetingReviewView: View {
    let app: AppCoordinator
    @State private var renaming: String?
    @State private var name = ""
    var body: some View {
        let m = app.meetings!
        if let f = m.last {
            HStack(spacing: 6) {
                MeetingCardTitle(symbol: "checkmark.circle", text: f.meta.title, tint: .green)
                Spacer(minLength: 0)
                Text("\(MeetingTime.duration(f.meta.durationS)) · \(f.lines.count) lines").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            if let o = f.summary?.overview, !o.isEmpty {
                Text(o).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            } else if !m.stage.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(m.stage).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
            } else if let e = m.summaryError {
                HStack(spacing: 6) {
                    Text("No summary: \(e)").font(.system(size: 10.5, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.4)).lineLimit(1)
                    IslandButton("Retry", symbol: "arrow.clockwise") { m.retrySummary() }
                }
            }
            HStack(spacing: 6) {
                Text("Speakers").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                ForEach(f.meta.speakers) { s in
                    let suggestion = f.summary?.participants.first { $0.speakerID == s.id }?.suggestedName
                    if renaming == s.id {
                        TextField(s.name, text: $name)
                            .textFieldStyle(.plain).font(.system(size: 11, design: .rounded)).foregroundStyle(.white).frame(width: 110)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.12)))
                            .onSubmit { m.rename(s.id, to: name); renaming = nil }
                    } else if let suggestion, suggestion != s.name {
                        IslandButton("\(s.name) → \(suggestion)?", symbol: "person.fill.questionmark") { m.acceptSuggestedName(s.id) }
                    } else {
                        IslandButton(s.name, symbol: s.isMe ? "person.fill" : "person") { renaming = s.id; name = s.name }
                    }
                }
            }
            HStack(spacing: 6) {
                IslandButton("Summary", symbol: "doc.text") { m.openSummary(); app.window.send(.acknowledged()) }
                IslandButton("Transcript", symbol: "text.quote") { m.openTranscript(); app.window.send(.acknowledged()) }
                IslandButton("Ask", symbol: "questionmark.bubble") { app.openKnowledge(question: "What was decided in the meeting \"\(f.meta.title)\"?") }
                IslandButton("Folder", symbol: "folder") { m.openFolder(); app.window.send(.acknowledged()) }
                IslandButton("Done", symbol: "checkmark") { m.dismiss() }
            }
        }
    }
}

struct MeetingFailedView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        MeetingCardTitle(symbol: "exclamationmark.triangle", text: "Couldn't write the notes", tint: .orange)
        Text(m.error ?? "").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(3)
        HStack(spacing: 6) {
            IslandButton("Retry", symbol: "arrow.clockwise") { m.retry() }
            IslandButton("Folder", symbol: "folder") { m.openFolder(); app.window.send(.acknowledged()) }
            IslandButton("Dismiss", symbol: "xmark") { m.dismiss() }
        }
    }
}

struct MeetingIdleView: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        HStack(spacing: 6) {
            MeetingCardTitle(symbol: "waveform", text: "Meeting notes")
            Spacer(minLength: 0)
            IslandButton("Start", symbol: "record.circle") { m.toggle() }
            IslandButton("Folder", symbol: "folder") { m.openFolder(); app.window.send(.acknowledged()) }
        }
        if m.recent.isEmpty {
            Text("Triple-click me in a call (or I'll ask when I notice one): I record both sides, transcribe on this Mac and file the notes.")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(3)
        } else {
            ForEach(m.recent.prefix(4), id: \.meta.id) { f in
                HStack(spacing: 6) {
                    Text(f.meta.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5)).frame(width: 110, alignment: .leading)
                    Text(f.meta.title).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { m.openSummary(f) } label: { Image(systemName: "doc.text").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    Button { m.openTranscript(f) } label: { Image(systemName: "text.quote").font(.system(size: 10)) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
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
        HStack(spacing: 3) {
            Text(label).font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.45))
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12)).frame(width: 36, height: 5)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(muted ? Color.orange.opacity(0.6) : Color.white.opacity(0.85))
                        .frame(width: muted ? 36 : CGFloat(min(1, level * 6)) * 36)
                }
            if muted { Image(systemName: "speaker.slash").font(.system(size: 8)).foregroundStyle(.orange.opacity(0.8)) }
        }
    }
}

/// The compact strip's REC pill while a meeting records.
struct RecPill: View {
    let app: AppCoordinator
    var body: some View {
        let m = app.meetings!
        HStack(spacing: 4) {
            RecDot()
            Text(MeetingTime.stamp(m.elapsed, millis: false).dropFirst(3)).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.red.opacity(0.25)))
    }
}
