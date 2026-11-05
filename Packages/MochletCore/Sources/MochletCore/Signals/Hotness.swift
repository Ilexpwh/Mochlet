import Foundation

/// How hot an event is: every distinct source that carried it in the last 48 hours counts by its tier,
/// and a mention's weight halves every 24 hours. `rising` compares with six hours earlier; `new` is
/// an event first seen under six hours ago.
public enum Hotness {
    public struct Mention: Sendable, Equatable {
        public var sourceID: String
        public var tier: SourceTier
        public var at: Date
        public init(sourceID: String, tier: SourceTier, at: Date) {
            self.sourceID = sourceID
            self.tier = tier
            self.at = at
        }
    }

    public static func score(_ mentions: [Mention], now: Date = Date(), window: TimeInterval = 48 * 3600) -> Double {
        var best: [String: Double] = [:]
        for m in mentions {
            let age = now.timeIntervalSince(m.at)
            guard age >= -600, age <= window else { continue }
            let w = m.tier.weight * pow(0.5, max(0, age) / (24 * 3600))
            best[m.sourceID] = max(best[m.sourceID] ?? 0, w)
        }
        return best.values.reduce(0, +)
    }

    public static func isRising(now current: Double, sixHoursAgo earlier: Double) -> Bool {
        current - earlier >= 1.0 || (earlier > 0 && (current - earlier) / earlier >= 0.4)
    }

    public static func isNew(firstSeen: Date, now: Date = Date()) -> Bool { now.timeIntervalSince(firstSeen) < 6 * 3600 }

    /// Worth a nudge from the slime: hot and new.
    public static func isExciting(hotness: Double, firstSeen: Date, now: Date = Date()) -> Bool { hotness >= 3.0 && isNew(firstSeen: firstSeen, now: now) }
}

/// When a source is fetched next: by its 7-day yield, with backoff on failures and floors per kind.
public enum SignalScheduling {
    public static func interval(kind: SourceKind, yieldPerDay: Double, failures: Int, configured: Int, hotSignal: Bool = false) -> TimeInterval {
        var minutes: Double
        switch yieldPerDay {
        case ..<0.01: minutes = 180
        case ..<0.5: minutes = 120
        case ..<2: minutes = 60
        case ..<6: minutes = 30
        default: minutes = 15
        }
        if configured > 0 { minutes = min(minutes, Double(configured)) }
        if kind == .xSearch { minutes = max(minutes, 30) }
        if hotSignal { minutes = min(minutes, 180) }
        if failures > 0 { minutes = min(minutes * pow(2, Double(min(failures, 8))), 12 * 60) }
        return minutes * 60
    }

    /// AIHOT's backfill rule: the first fetch takes up to `initialLimit` items within 12 months; later
    /// fetches take items up to 48 hours old and flag older ones as backfill.
    public static func backfill(published: Date?, firstFetch: Bool, now: Date = Date()) -> (take: Bool, backfill: Bool) {
        guard let published else { return (true, false) }
        let age = now.timeIntervalSince(published)
        if firstFetch { return (age <= 366 * 24 * 3600, age > 48 * 3600) }
        return (true, age > 48 * 3600)
    }
}
