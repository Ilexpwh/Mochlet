import SwiftUI
import MochletCore

/// The What's new card: a title, a few lines, Got it.
struct WhatsNewView: View {
    let app: AppCoordinator

    var body: some View {
        let note = WhatsNew.current
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(symbol: "sparkles", tint: IslandStyle.attention, title: note?.title ?? "What's new", meta: "v\(WhatsNew.version)", app: app)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((note?.lines ?? []).enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(IslandStyle.ink3).frame(width: 4, height: 4).padding(.top, 7)
                        Text(line).islandBody().lineLimit(3)
                    }
                }
            }
            HStack(spacing: 6) {
                IslandButton("Got it", symbol: "checkmark", role: .primary, keycap: "⏎") { app.dismissWhatsNew() }
                IslandButton("Settings", symbol: "gearshape") { app.dismissWhatsNew(); app.openSettings() }
                Spacer(minLength: 0)
                IslandButton("Guide", symbol: "book", role: .quiet) { app.dismissWhatsNew(); app.openGuide() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .reportsIslandHeight(for: .whatsNew)
    }
}
