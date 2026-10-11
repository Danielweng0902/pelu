import Foundation

/// Parses `~/Library/Application Support/Claude/plan-usage-history.json`,
/// where the Claude desktop app keeps plan usage samples:
/// `{"version": 2, "samples": [{"t": <ms>, "org": "…", "u": {"fh": 10, "sd": 2}}]}`
/// (`fh` = five-hour %, `sd` = seven-day %).
///
/// A fallback for when Claude Code's token has expired because only the
/// Claude app was used. The app writes it rarely (seen only at launch) and
/// samples carry no reset times, so a window whose length has passed since
/// the sample is dropped rather than shown as current or zeroed.
public struct ClaudeDesktopUsageParser: Sendable {
    public init() {}

    static let primaryWindowMins = 300
    static let secondaryWindowMins = 10080

    /// Latest sample with any usage, or nil when there is none still inside its window.
    public func parse(data: Data, now: Date = Date()) -> UsageMetric? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = object["samples"] as? [[String: Any]] else { return nil }

        var latest: (date: Date, primary: Double?, secondary: Double?)?
        for sample in samples {
            guard let ms = (sample["t"] as? NSNumber)?.doubleValue,
                  let usage = sample["u"] as? [String: Any] else { continue }
            let primary = (usage["fh"] as? NSNumber)?.doubleValue
            let secondary = (usage["sd"] as? NSNumber)?.doubleValue
            guard primary != nil || secondary != nil else { continue }
            let date = Date(timeIntervalSince1970: ms / 1000)
            if latest.map({ date > $0.date }) ?? true {
                latest = (date, primary, secondary)
            }
        }
        guard let latest, latest.date <= now.addingTimeInterval(60) else { return nil }

        let age = now.timeIntervalSince(latest.date)
        let primary = age < Double(Self.primaryWindowMins * 60) ? latest.primary : nil
        let secondary = age < Double(Self.secondaryWindowMins * 60) ? latest.secondary : nil
        guard primary != nil || secondary != nil else { return nil }

        return UsageMetric(
            provider: .claudeCode,
            usedPercent: primary,
            weeklyPercent: secondary,
            primaryWindowDurationMins: Self.primaryWindowMins,
            secondaryWindowDurationMins: Self.secondaryWindowMins,
            dataSource: .officialQuota,
            measuredAt: latest.date
        )
    }

    #if os(macOS)
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    public func read(from url: URL = ClaudeDesktopUsageParser.defaultFileURL, now: Date = Date()) -> UsageMetric? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, now: now)
    }
    #endif
}
