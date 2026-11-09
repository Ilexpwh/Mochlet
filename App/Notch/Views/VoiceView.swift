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
                Text(title(v)).font(IslandStyle.title).foregroundStyle(IslandStyle.ink).lineLimit(1)
                Spacer(minLength: 8)
                if !v.localeID.isEmpty {
                    Text(v.localeID).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint)
                }
                CardTools(app: app)
            }
            .frame(minHeight: 26)
            if v.hasSpeech || v.state == .listening {
                (Text(VoiceController.join(v.finals)) + Text(v.finals.isEmpty || v.caption.isEmpty ? "" : " ") + Text(v.caption).foregroundStyle(IslandStyle.ink3))
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(IslandStyle.ink)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let p = v.pending {
                FlowLayout(spacing: 6) {
                    ForEach(app.projects.projects.filter { !$0.archived }.prefix(4), id: \.slug) { pr in
                        ChipButton(text: pr.name, symbol: "folder") { v.answerPending(project: pr) }
                    }
                    ChipButton(text: "Cancel", symbol: "xmark") { v.answerPending(project: nil) }
                }
                Text(expires(p)).font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).monospacedDigit()
            } else if let e = v.error, v.state == .failed {
                Text(e).font(IslandStyle.secondary).foregroundStyle(IslandStyle.error).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                KeyHint(hints(v))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func hints(_ v: VoiceController) -> [(String, String)] {
        switch v.state {
        case .listening: return [("release", "send"), ("esc", "cancel")]
        case .processing: return [("…", v.lastIntent.map { "\($0.intent.rawValue) · \($0.backend)" } ?? "deciding what you meant")]
        default: return [("hold", "the slime to talk"), ("⌃⌥V", "push to talk")]
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
        .accessibilityLabel(active ? "Listening" : "Microphone idle")
    }

    private func bar(_ i: Int, at date: Date) -> Double {
        guard active else { return 0 }
        let phase = Double(i) * 0.9 + date.timeIntervalSinceReferenceDate * 7
        let wobble = 0.5 + 0.5 * sin(phase)
        return min(1, max(0.05, level * (0.6 + 0.4 * wobble)))
    }
}
