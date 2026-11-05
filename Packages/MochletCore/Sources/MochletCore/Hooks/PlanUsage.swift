import Foundation

/// One rate-limit window (5 h or 7 d) of a subscription plan.
public struct UsageWindow: Sendable, Equatable, Codable {
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
    public func effectivePercent(now: Date) -> Double {
        if let r = resetsAt, r <= now { return 0 }
        return usedPercent
    }
}

/// Plan usage as shown by the pills: green < 50, amber < 80, else red.
public struct PlanUsage: Sendable, Equatable, Codable {
    public var fiveHour: UsageWindow?
    public var week: UsageWindow?
    public var planType: String?
    public var updatedAt: Date

    public init(fiveHour: UsageWindow?, week: UsageWindow?, planType: String? = nil, updatedAt: Date) {
        self.fiveHour = fiveHour
        self.week = week
        self.planType = planType
        self.updatedAt = updatedAt
    }

    public func dominantPercent(now: Date) -> Double {
        max(fiveHour?.effectivePercent(now: now) ?? 0, week?.effectivePercent(now: now) ?? 0)
    }

    public enum Level: String, Sendable { case low, mid, high, none }
    public static func level(_ pct: Double?) -> Level {
        guard let p = pct else { return .none }
        if p < 50 { return .low }
        if p < 80 { return .mid }
        return .high
    }

    static let maxFuture: TimeInterval = 400 * 86400

    static func window(_ j: JSONValue, now: Date) -> UsageWindow? {
        guard var pct = j["used_percentage"].number ?? j["usedPercent"].number else { return nil }
        guard pct >= 0, pct <= 200 else { return nil }
        pct = min(100, pct)
        var resets: Date?
        if let r = j["resets_at"].number ?? j["resetsAt"].number, r > 0, r <= now.timeIntervalSince1970 + maxFuture {
            resets = Date(timeIntervalSince1970: r)
        }
        return UsageWindow(usedPercent: pct, resetsAt: resets)
    }

    /// Claude Code statusline `rate_limits` → usage. Nil when neither window parses.
    public static func fromClaude(rateLimits: JSONValue, now: Date = Date()) -> PlanUsage? {
        let five = window(rateLimits["five_hour"], now: now)
        let week = window(rateLimits["seven_day"], now: now)
        guard five != nil || week != nil else { return nil }
        return PlanUsage(fiveHour: five, week: week, updatedAt: now)
    }

    /// `codex app-server` `account/rateLimits/read` result → usage.
    public static func fromCodex(result: JSONValue, now: Date = Date()) -> PlanUsage? {
        let limits = result["rateLimits"]
        var five: UsageWindow?
        var week: UsageWindow?
        for key in ["primary", "secondary"] {
            let w = limits[key]
            guard let pct = w["usedPercent"].number else { continue }
            let resets = w["resetsAt"].number.map { Date(timeIntervalSince1970: $0) }
            let window = UsageWindow(usedPercent: min(100, max(0, pct)), resetsAt: resets)
            if let mins = w["windowDurationMins"].int, mins <= 1440 { five = window } else { week = window }
        }
        guard five != nil || week != nil else { return nil }
        return PlanUsage(fiveHour: five, week: week, planType: limits["planType"].string, updatedAt: now)
    }

    /// "in 2 h 05", "in 12 min", "Resetting…" or nil.
    public static func resetLabel(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "Resetting…" }
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        if h >= 48 { return "in \(h / 24) d \(h % 24) h" }
        return h > 0 ? String(format: "in %d h %02d", h, m) : "in \(m) min"
    }
}
