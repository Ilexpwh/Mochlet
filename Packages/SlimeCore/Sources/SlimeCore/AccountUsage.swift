import Foundation

public struct AccountUsageWindow: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let usedPercent: Double
    public let minutes: Int?
    public let resetsAt: Date?
    public var durationLabel: String {
        guard let minutes else { return name }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
    public func isStale(observedAt: Date?, now: Date) -> Bool {
        guard let observedAt else { return true }
        return now.timeIntervalSince(observedAt) > 300 || observedAt.timeIntervalSince(now) > 300 || (resetsAt.map { $0 <= now } ?? false)
    }
}
public struct AccountUsageBucket: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let windows: [AccountUsageWindow]
    public static func parse(_ value: JSONValue) -> [Self] {
        let buckets = value["rateLimitsByLimitId"].object
        let values = buckets.isEmpty ? ["codex": value["rateLimits"]] : buckets
        return values.keys.sorted().compactMap { key in
            guard let bucket = values[key], bucket != .null else { return nil }
            let windows = ["primary", "secondary"].compactMap { name -> AccountUsageWindow? in
                let window = bucket[name]
                guard let used = window["usedPercent"].number, used.isFinite else { return nil }
                let duration = window["windowDurationMins"].number
                let minutes = duration.flatMap { $0.isFinite && $0 > 0 && $0 <= 525_600 ? Int($0) : nil }
                let resets = window["resetsAt"].number.flatMap { $0.isFinite && $0 > 0 && $0 < 100_000_000_000 ? Date(timeIntervalSince1970: $0) : nil }
                return AccountUsageWindow(id: key + "/" + name, name: name.capitalized, usedPercent: min(100, max(0, used)), minutes: minutes, resetsAt: resets)
            }
            return Self(id: key, name: bucket["limitName"].string ?? key, windows: windows)
        }
    }
}
