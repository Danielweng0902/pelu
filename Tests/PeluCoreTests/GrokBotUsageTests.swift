import CloudKit
import Foundation
import Testing
@testable import PeluCore

private let status = """
{"currentPeriodStart":"2026-10-08T07:49:44.208Z","nextResetTimestampUtc":"2026-10-15T07:49:44.208Z","usagePercent":51.245305,
 "hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"Grok Bot Plan","cursorPlanName":"Pro",
 "billingBrand":"SAND_BILLING_BRAND_CURSOR"}
"""

private let fetchedAt = Date(timeIntervalSince1970: 1_791_600_000) // 2026-10-10

@Test func grokBotStatusMapsToWeeklyPrimaryWindow() throws {
    let reading = try #require(try GrokBotUsageParser().parse(data: Data(status.utf8), fetchedAt: fetchedAt))
    let metric = reading.metric(at: fetchedAt)

    #expect(metric.provider == .grokBot)
    #expect(abs((metric.usedPercent ?? 0) - 51.2453) < 0.001)
    #expect(metric.weeklyPercent == nil)
    #expect(metric.primaryWindowDurationMins == 7 * 24 * 60)
    #expect(metric.windowTitle(secondary: false) == "7 日")
    let reset = try #require(metric.resetDate)
    #expect(abs(reset.timeIntervalSince1970 - 1_792_050_584.208) < 0.01)
    #expect(metric.dataSource == .officialQuota)
    #expect(metric.measuredAt == fetchedAt)
}

@Test func grokBotZeroesAfterWeeklyReset() throws {
    let reading = try #require(try GrokBotUsageParser().parse(data: Data(status.utf8), fetchedAt: fetchedAt))
    let metric = reading.metric(at: fetchedAt.addingTimeInterval(7 * 86400))
    #expect(metric.usedPercent == 0)
    #expect(metric.status == .normal)
}

@Test func grokBotPooledEnterpriseHasNoPersonalReading() throws {
    let json = #"{"usesPooledEnterpriseAllowance":true,"hasNonZeroIncludedLimit":true}"#
    #expect(try GrokBotUsageParser().parse(data: Data(json.utf8), fetchedAt: fetchedAt) == nil)
}

@Test func grokBotWithoutPercentIsUnreadable() {
    let json = #"{"nextResetTimestampUtc":"2026-10-15T07:49:44.208Z"}"#
    #expect(throws: ParserError.self) {
        try GrokBotUsageParser().parse(data: Data(json.utf8), fetchedAt: fetchedAt)
    }
}

@Test func grokBotShowsOnlyWhenUsedOrInstalledWithAccess() throws {
    let used = try #require(try GrokBotUsageParser().parse(data: Data(status.utf8), fetchedAt: fetchedAt))
    #expect(used.isWorthShowing(appInstalled: false))

    let untouched = status.replacingOccurrences(of: "\"usagePercent\":51.245305", with: "\"usagePercent\":0")
    let idle = try #require(try GrokBotUsageParser().parse(data: Data(untouched.utf8), fetchedAt: fetchedAt))
    #expect(!idle.isWorthShowing(appInstalled: false))
    #expect(idle.isWorthShowing(appInstalled: true))

    let noAccess = untouched.replacingOccurrences(of: "\"hasNonZeroIncludedLimit\":true", with: "\"hasNonZeroIncludedLimit\":false")
    let locked = try #require(try GrokBotUsageParser().parse(data: Data(noAccess.utf8), fetchedAt: fetchedAt))
    #expect(!locked.isWorthShowing(appInstalled: true))
}

@Test func grokBotTravelsInExtraMetrics() throws {
    let mac = MacSnapshot(macId: "m", label: "Mac", snapshot: UsageSnapshot(
        generatedAt: fetchedAt,
        source: .local,
        metrics: [
            UsageMetric(provider: .claudeCode, usedPercent: 37),
            UsageMetric(provider: .codex, usedPercent: 10),
            UsageMetric(provider: .grokBot, usedPercent: 51, primaryWindowDurationMins: 7 * 1440, measuredAt: fetchedAt),
        ]
    ))
    let record = try MacSnapshotRecord.makeRecord(from: mac, bundleVersion: "test")
    let payload = try #require(record["payload"] as? Data)
    #expect(try JSONDecoder.peluAPI.decode([UsageMetric].self, from: payload).map(\.provider) == [.claudeCode, .codex])
    #expect(try MacSnapshotRecord.decode(record).snapshot.metric(for: .grokBot)?.usedPercent == 51)
}

@Test func aggregateUsesNewestGrokBotMeasurement() {
    let old = fetchedAt
    let new = old.addingTimeInterval(600)
    let aggregate = AggregateSnapshot(macs: [
        MacSnapshot(macId: "a", label: "A", snapshot: UsageSnapshot(generatedAt: old, source: .cloud, metrics: [
            UsageMetric(provider: .grokBot, usedPercent: 80, measuredAt: old),
        ])),
        MacSnapshot(macId: "b", label: "B", snapshot: UsageSnapshot(generatedAt: new, source: .cloud, metrics: [
            UsageMetric(provider: .grokBot, usedPercent: 5, measuredAt: new),
        ])),
    ])
    #expect(aggregate.displaySnapshot(at: new)?.metric(for: .grokBot)?.usedPercent == 5)
}
