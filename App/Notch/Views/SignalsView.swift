import SwiftUI
import MochletCore

/// The Signals card: what is hot right now, today's count, the digest and the sources.
struct SignalsView: View {
    let app: AppCoordinator

    var body: some View {
        let s = app.signals!
        let busy = s.isRunning || s.isComposing
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "antenna.radiowaves.left.and.right", tint: IslandStyle.working, title: "AI signals",
                       subtitle: busy ? (s.stage ?? (s.isComposing ? "composing…" : "fetching…")) : nil, meta: counts(s), app: app) {
                if busy { ProgressView().controlSize(.mini).tint(.white) }
            }
            if !s.enabled {
                EmptyState(symbol: "antenna.radiowaves.left.and.right.slash", line: "Signals are off.", hint: "Turn them on in Settings → Signals.")
            } else if s.status.hot.isEmpty {
                EmptyState(symbol: "sparkles", line: "Nothing hot yet.",
                           hint: s.status.itemsToday == 0 && s.lastRun == nil ? "The first run starts shortly after launch; Run now fetches every source."
                               : s.brainLabel == nil ? "Items arrive but nothing can be scored: pick a chat backend under Settings → Chat so the brain can read them."
                               : "Events light up when several sources carry a story within two days.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(s.status.hot.prefix(3)) { e in
                        ListRow(action: { s.open(event: e); app.window.send(.acknowledged()) }) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(format: "%.1f", e.hotness))
                                    .font(IslandStyle.captionStrong).monospacedDigit()
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(e.hotness >= 3 ? IslandStyle.attention : Color.white.opacity(0.75)))
                                    .padding(.top, 2)
                                Text(e.title).font(IslandStyle.body).foregroundStyle(IslandStyle.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                if e.rising { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(IslandStyle.attention).padding(.top, 3) }
                                Spacer(minLength: 0)
                                Text("×\(e.sourceCount)").font(IslandStyle.caption).foregroundStyle(IslandStyle.hint).monospacedDigit().padding(.top, 2)
                            }
                            .padding(.vertical, 3)
                        }
                        .accessibilityLabel("\(e.title), hotness \(String(format: "%.1f", e.hotness)), \(e.sourceCount) sources")
                    }
                }
            }
            if let e = s.lastError, s.status.hot.count < 3 {
                Text(e).font(IslandStyle.caption).foregroundStyle(IslandStyle.error.opacity(0.9)).lineLimit(1)
            }
            HStack(spacing: 6) {
                IslandButton(s.status.latestDigest.map { "Digest \($0.day.suffix(5))" } ?? "Digest", symbol: "doc.text", role: .primary) { s.openDigest() }
                IslandButton("Sources", symbol: "list.bullet") { app.openSettings(tab: "signals") }
                IslandButton(s.isRunning ? "Running…" : "Run now", symbol: "arrow.clockwise") { s.runNow() }
                Spacer(minLength: 0)
                IslandButton("Ask", symbol: "questionmark.bubble", role: .quiet) { app.openKnowledge(question: "What were the most important AI signals in the latest digest, and why?") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .signals)
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
