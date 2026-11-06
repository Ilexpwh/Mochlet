import SwiftUI
import MochletCore

/// The Signals card: what is hot right now, today's count, the digest and the sources.
struct SignalsView: View {
    let app: AppCoordinator

    var body: some View {
        let s = app.signals!
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
                Text("AI signals").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                if s.isRunning || s.isComposing {
                    ProgressView().controlSize(.mini)
                    Text(s.stage ?? (s.isComposing ? "composing" : "fetching")).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(counts(s)).font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            if !s.enabled {
                Text("Signals are off. Turn them on in Settings → Signals.").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7))
            } else if s.status.hot.isEmpty {
                Text(s.status.itemsToday == 0 && s.lastRun == nil ? "Nothing fetched yet. The first run starts shortly after launch; Run now fetches every source."
                     : s.brainLabel == nil ? "Items arrive but nothing can be scored: pick a chat backend under Settings → Chat so the brain can read them."
                     : "No story is hot yet. Events light up when several sources carry them within two days.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            } else {
                ForEach(s.status.hot.prefix(3)) { e in
                    Button { s.open(event: e); app.window.send(.acknowledged()) } label: {
                        HStack(spacing: 6) {
                            Text(String(format: "%.1f", e.hotness))
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(e.hotness >= 3 ? Color(red: 1.0, green: 0.62, blue: 0.35) : Color.white.opacity(0.75)))
                            Text(e.title).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                            if e.rising { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.35)) }
                            Text("×\(e.sourceCount)").font(.system(size: 9.5, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let e = s.lastError, s.status.hot.count < 3 {
                Text(e).font(.system(size: 10, design: .rounded)).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.4)).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                IslandButton(s.status.latestDigest.map { "Digest \($0.day.suffix(5))" } ?? "Digest", symbol: "doc.text") { s.openDigest() }
                IslandButton("Sources", symbol: "list.bullet") { app.openSettings(tab: "signals") }
                IslandButton(s.isRunning ? "Running…" : "Run now", symbol: "arrow.clockwise") { s.runNow() }
                IslandButton("Ask", symbol: "questionmark.bubble") { app.openKnowledge(question: "What were the most important AI signals in the latest digest, and why?") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { s.refreshStatus() }
    }

    private func counts(_ s: SignalsController) -> String {
        var parts = ["\(s.status.itemsToday) today"]
        if s.status.acceptedToday > 0 { parts.append("\(s.status.acceptedToday) kept") }
        let hot = s.status.hot.filter { $0.hotness >= 2 }.count
        if hot > 0 { parts.append("\(hot) hot") }
        return parts.joined(separator: " · ")
    }
}
