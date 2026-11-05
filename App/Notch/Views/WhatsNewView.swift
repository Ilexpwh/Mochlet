import SwiftUI
import MochletCore

/// The What's new card: a title, a few lines, Got it.
struct WhatsNewView: View {
    let app: AppCoordinator

    var body: some View {
        let note = WhatsNew.current
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.45))
                Text(note?.title ?? "What's new").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Spacer(minLength: 0)
                Text("v\(WhatsNew.version)").font(.system(size: 10, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array((note?.lines ?? []).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                    Text(line).font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.85)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                IslandButton("Got it", symbol: "checkmark") { app.dismissWhatsNew() }
                IslandButton("Settings", symbol: "gearshape") { app.dismissWhatsNew(); app.openSettings() }
                IslandButton("Guide", symbol: "book") { app.dismissWhatsNew(); app.openGuide() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
