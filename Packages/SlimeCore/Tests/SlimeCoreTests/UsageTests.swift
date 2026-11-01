import Foundation
import Testing
@testable import SlimeCore

@Test func usageDoesNotInventMissingOrResetExpiredLimits() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let value: JSONValue = .object(["rateLimitsByLimitId": .object([
        "codex": .object(["primary": .object(["usedPercent": .number(87), "windowDurationMins": .number(300), "resetsAt": .number(now.timeIntervalSince1970 - 10)]), "secondary": .null]),
        "other": .object(["primary": .object(["usedPercent": .number(110)])])
    ])])
    let buckets = AccountUsageBucket.parse(value)
    #expect(buckets.count == 2 && buckets[0].windows.count == 1)
    let window = try #require(buckets.first?.windows.first)
    #expect(window.usedPercent == 87 && window.durationLabel == "5-hour")
    #expect(window.isStale(observedAt: now, now: now))
    #expect(buckets[1].windows[0].usedPercent == 100)
    #expect(buckets[1].windows[0].isStale(observedAt: now.addingTimeInterval(-301), now: now))
    #expect(AccountUsageBucket.parse(.null).isEmpty)
}
