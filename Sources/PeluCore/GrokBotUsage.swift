import Foundation

/// One reading of `aiserver.v1.DashboardService/GetSandUsageStatus`, the
/// undocumented Connect RPC behind Grok Bot's Usage & Billing screen. Grok Bot
/// (internally "sand") signs in with a Cursor account, and its included usage
/// is a single pool that resets weekly, separate from Cursor's plan pools.
public struct GrokBotUsageStatus: Equatable, Sendable {
    public let usedPercent: Double
    public let periodStart: Date?
    public let resetDate: Date?
    /// The plan includes Grok Bot usage at all (false on plans without access).
    public let hasIncludedLimit: Bool
    public let fetchedAt: Date

    /// Worth a tile: the pool has been touched, or the plan includes Grok Bot
    /// and the user has the desktop app.
    public func isWorthShowing(appInstalled: Bool) -> Bool {
        usedPercent > 0 || (appInstalled && hasIncludedLimit)
    }

    public func metric(at now: Date = Date()) -> UsageMetric {
        var windowMins = 7 * 24 * 60
        if let periodStart, let resetDate, resetDate > periodStart {
            windowMins = Int((resetDate.timeIntervalSince(periodStart) / 60).rounded())
        }
        return UsageMetric(
            provider: .grokBot,
            usedPercent: usedPercent,
            primaryWindowDurationMins: windowMins,
            resetDate: resetDate,
            dataSource: .officialQuota,
            measuredAt: fetchedAt
        ).effective(at: now)
    }
}

public struct GrokBotUsageParser: Sendable {
    public init() {}

    /// nil when the account draws on a pooled enterprise allowance, which has
    /// no per-person percentage.
    public func parse(data: Data, fetchedAt: Date) throws -> GrokBotUsageStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.unreadableJSON
        }
        if (object["usesPooledEnterpriseAllowance"] as? Bool) == true { return nil }
        guard let percent = (object["usagePercent"] as? NSNumber)?.doubleValue, percent.isFinite else {
            throw ParserError.unreadableJSON
        }
        return GrokBotUsageStatus(
            usedPercent: max(0, percent),
            periodStart: Self.date(object["currentPeriodStart"]),
            resetDate: Self.date(object["nextResetTimestampUtc"]),
            hasIncludedLimit: (object["hasNonZeroIncludedLimit"] as? Bool) == true,
            fetchedAt: fetchedAt
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

#if os(macOS)
/// Polls Grok Bot's weekly usage with the Cursor app's session token (the same
/// Cursor account Grok Bot signs in with). Grok Bot's own tokens are encrypted
/// with its Keychain key and are deliberately left alone, so this needs Cursor
/// signed in on this Mac. Never refreshes tokens.
public final class GrokBotUsageClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable () -> Void

    private static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    private static let appSupportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot")
    /// Spacing while the Grok Bot desktop app is writing its state.
    static let activeInterval: TimeInterval = 300
    static let idleInterval: TimeInterval = 900
    /// Without the desktop app, only look now and then for Bots run from the phone.
    static let appMissingInterval: TimeInterval = 3600
    private static let backoffSeconds: [TimeInterval] = [300, 900, 1800, 3600]

    private let queue = DispatchQueue(label: "org.tobywu.pelu.grokbot-usage", qos: .utility)
    private let userAgent: String
    private let session: URLSession

    // Owned by `queue`.
    private var token: CursorUsageClient.Token?
    private var nextAttemptAt = Date.distantPast
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0
    private var isInFlight = false
    private let stateLock = NSLock()
    private var latest: GrokBotUsageStatus?
    private var problem: String?

    public var onUpdate: UpdateHandler?

    public init(clientVersion: String) {
        userAgent = "Pelu/\(clientVersion)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    /// Cursor (the token source) has been signed in on this Mac at some point.
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: CursorUsageClient.databaseURL.path)
    }

    public var isAppInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.appSupportURL.path)
    }

    /// Latest reading, a placeholder explaining what is missing, or nil when
    /// Grok Bot isn't in use and shouldn't take a tile.
    public func currentMetric(now: Date = Date()) -> UsageMetric? {
        let (latest, problem) = stateLock.withLock { (latest, problem) }
        let appInstalled = isAppInstalled
        if let latest {
            return latest.isWorthShowing(appInstalled: appInstalled) ? latest.metric(at: now) : nil
        }
        guard appInstalled else { return nil }
        return UsageMetric(provider: .grokBot, usedPercent: nil, note: problem ?? "正在讀取 Grok Bot 用量")
    }

    public func refreshIfDue() {
        queue.async { [weak self] in
            guard let self, !self.isInFlight, self.isAvailable else { return }
            let now = Date()
            let appInstalled = self.isAppInstalled
            guard ClaudeUsageAPIClient.isDue(
                now: now,
                nextAttemptAt: self.nextAttemptAt,
                lastAttemptAt: self.lastAttemptAt,
                lastActivityAt: appInstalled ? Self.latestAppWrite() : nil,
                activeInterval: Self.activeInterval,
                idleInterval: appInstalled ? Self.idleInterval : Self.appMissingInterval
            ) else { return }
            guard let token = self.currentToken(now: now) else {
                self.nextAttemptAt = now.addingTimeInterval(Self.backoffSeconds[0])
                self.onUpdate?()
                return
            }
            self.isInFlight = true
            self.lastAttemptAt = now
            self.fetch(token: token)
        }
    }

    /// Newest mtime among the top-level entries of Grok Bot's support folder.
    private static func latestAppWrite() -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: appSupportURL, includingPropertiesForKeys: keys) else {
            return nil
        }
        return entries
            .compactMap { try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate }
            .max()
    }

    private func fetch(token: CursorUsageClient.Token) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token.jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.isInFlight = false
                let now = Date()
                // A nil reading is a pooled team allowance, not a failure.
                var parsed: Result<GrokBotUsageStatus?, Error>?
                if status == 200, let data {
                    parsed = Result { try GrokBotUsageParser().parse(data: data, fetchedAt: now) }
                }
                if case .success(let reading)? = parsed {
                    self.stateLock.withLock {
                        self.latest = reading
                        self.problem = reading == nil ? "這個帳號的 Grok Bot 額度由團隊共用，沒有個人用量" : nil
                    }
                    self.consecutiveFailures = 0
                    self.nextAttemptAt = .distantPast
                    self.onUpdate?()
                    return
                }
                if status == 401 || status == 403 { self.token = nil }
                self.consecutiveFailures += 1
                let delay = Self.backoffSeconds[min(self.consecutiveFailures, Self.backoffSeconds.count) - 1]
                self.nextAttemptAt = now.addingTimeInterval(delay)
                self.setProblem(status == 401 || status == 403 ? "Cursor 登入已失效，請開啟 Cursor 重新登入" : "暫時讀不到 Grok Bot 用量")
                NSLog("Pelu Grok Bot usage failed (HTTP \(status), \(error?.localizedDescription ?? "-")), retry in \(Int(delay))s")
            }
        }.resume()
    }

    private func setProblem(_ message: String) {
        stateLock.withLock { problem = message }
    }

    private func currentToken(now: Date) -> CursorUsageClient.Token? {
        if let token, token.expiresAt.map({ $0 > now }) ?? true { return token }
        token = CursorUsageClient.readToken()
        guard let token else {
            setProblem("Grok Bot 用量要在這台 Mac 的 Cursor 登入同一個帳號")
            return nil
        }
        guard token.expiresAt.map({ $0 > now }) ?? true else {
            setProblem("Cursor 登入已過期，請開啟 Cursor")
            return nil
        }
        return token
    }
}
#endif // os(macOS)
