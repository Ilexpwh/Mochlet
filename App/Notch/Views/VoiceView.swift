import SwiftUI
import MochletCore

/// What the ask bubble shows while push-to-talk is live: level bars, the words as they form, then the
/// router's follow-up question when it needs one more answer.
struct VoiceView: View {
    let app: AppCoordinator

    var body: some View {
        let v = app.voice!
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MicBars(level: v.level, active: v.state == .listening)
                Text(title(v))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if !v.localeID.isEmpty {
                    Text(v.localeID).font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.4))
                }
            }
            if v.hasSpeech || v.state == .listening {
                (Text(VoiceController.join(v.finals)) + Text(v.finals.isEmpty || v.caption.isEmpty ? "" : " ") + Text(v.caption).foregroundStyle(.white.opacity(0.5)))
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let p = v.pending {
                HStack(spacing: 6) {
                    ForEach(app.projects.projects.filter { !$0.archived }.prefix(4), id: \.slug) { pr in
                        IslandButton(pr.name, symbol: "folder") { v.answerPending(project: pr) }
                    }
                    IslandButton("Cancel", symbol: "xmark") { v.answerPending(project: nil) }
                }
                Text(expires(p))
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            } else if let e = v.error, v.state == .failed {
                Text(e).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.orange.opacity(0.9)).lineLimit(2)
            } else {
                Text(hint(v))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func title(_ v: VoiceController) -> String {
        switch v.state {
        case .preparing: return "Getting ready…"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .waiting: return v.pending?.question ?? "One more thing…"
        case .failed: return "Couldn't listen"
        case .idle: return v.lastAction.map { "Done: \($0)" } ?? "Voice"
        }
    }

    private func hint(_ v: VoiceController) -> String {
        switch v.state {
        case .listening: return "release to send · esc cancels"
        case .processing: return v.lastIntent.map { "\($0.intent.rawValue) · \($0.backend)" } ?? "deciding what you meant…"
        default: return "hold the slime or ⌃⌥V to talk"
        }
    }

    private func expires(_ p: VoiceController.Pending) -> String {
        let s = max(0, Int(p.deadline.timeIntervalSinceNow.rounded()))
        return "say the name or tap one · \(s) s"
    }
}

/// Five bars that follow the microphone level with a little lag per bar.
struct MicBars: View {
    var level: Double
    var active: Bool
    @State private var shown: [Double] = [0, 0, 0, 0, 0]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { ctx in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(active ? 0.9 : 0.35))
                        .frame(width: 3, height: 4 + 12 * bar(i, at: ctx.date))
                }
            }
            .frame(width: 24, height: 18)
        }
    }

    private func bar(_ i: Int, at date: Date) -> Double {
        guard active else { return 0 }
        let phase = Double(i) * 0.9 + date.timeIntervalSinceReferenceDate * 7
        let wobble = 0.5 + 0.5 * sin(phase)
        return min(1, max(0.05, level * (0.6 + 0.4 * wobble)))
    }
}
