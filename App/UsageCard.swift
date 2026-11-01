import SwiftUI
import SlimeCore

struct UsageCard: View {
    let value: JSONValue
    let observedAt: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AccountUsageBucket.parse(value)) { bucket in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(bucket.name).font(.headline)
                        if bucket.windows.isEmpty { Text("Limits unavailable").foregroundStyle(.secondary) }
                        ForEach(bucket.windows) { window in UsageGauge(window: window, observedAt: observedAt, now: timeline.date) }
                    }
                }
                if let observedAt { Text("Updated \(observedAt.formatted()). Account allowance is separate from API spending.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

// Capsule layout adapted from Coucou GaugeRowView, Copyright (c) 2026 Louis Raillé.
// MIT license bundled in Resources/Coucou-MIT.txt. Stale snapshots are never reset to zero.
private struct UsageGauge: View {
    let window: AccountUsageWindow
    let observedAt: Date?
    let now: Date
    var stale: Bool { window.isStale(observedAt: observedAt, now: now) }
    var accent: Color { stale ? .secondary : window.usedPercent >= 90 ? .red : window.usedPercent >= 75 ? .orange : .mint }
    var body: some View {
        HStack(spacing: 10) {
            Text(window.durationLabel).font(.caption).frame(width: 74, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(accent).frame(width: 70 * window.usedPercent / 100)
            }.frame(width: 70, height: 5)
            Text("\(Int(window.usedPercent.rounded()))% used").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 72, alignment: .trailing)
            if stale { Text("Refresh needed").font(.caption).foregroundStyle(.secondary) }
            else if let reset = window.resetsAt { Text("Resets \(reset.formatted(.dateTime.weekday().hour().minute()))").font(.caption).foregroundStyle(.secondary) }
            else { Text("Reset unavailable").font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.durationLabel), \(Int(window.usedPercent.rounded())) percent used. \(stale ? "Snapshot stale; refresh needed." : "")")
    }
}
