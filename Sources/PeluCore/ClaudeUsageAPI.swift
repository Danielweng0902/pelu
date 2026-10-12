import Foundation
#if canImport(Security)
import Security
#endif

/// Parses the response of `GET https://api.anthropic.com/api/oauth/usage`,
/// the endpoint behind Claude Code's `/usage`. Unlike the statusLine hook it
/// reflects usage from every Claude surface (terminal, IDE extensions,
/// desktop, claude.ai), so it is the primary Claude source on the Mac.
public struct ClaudeUsageAPIParser: Sendable {
    public init() {}

    /// `generatedAt` is "now" for reset checks; `fetchedAt` is when the
    /// response arrived and becomes the metric's `measuredAt`.
    public func parse(data: Data, fetchedAt: Date, generatedAt: Date = Date()) throws -> UsageMetric {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParserError.unreadableJSON
        }
        let fiveHour = object["five_hour"] as? [String: Any]
        let sevenDay = object["seven_day"] as? [String: Any]
        let primary = (fiveHour?["utilization"] as? NSNumber)?.doubleValue
        let secondary = (sevenDay?["utilization"] as? NSNumber)?.doubleValue
        guard primary != nil || secondary != nil else { throw ParserError.unreadableJSON }

        let resetDate = Self.date(fiveHour?["resets_at"])
        let weeklyResetDate = Self.date(sevenDay?["resets_at"])
        return UsageMetric(
            provider: .claudeCode,
            usedPercent: primary,
            weeklyPercent: secondary,
            primaryWindowDurationMins: 300,
            secondaryWindowDurationMins: 10080,
            resetDate: resetDate,
            weeklyResetDate: weeklyResetDate,
            dataSource: .officialQuota,
            measuredAt: fetchedAt
        ).effective(at: generatedAt)
    }

    /// Prefer whichever reading is newer. The API and the Claude app have no
    /// session context or cost, so those stay from the hook when it has them.
    public static func merge(api: UsageMetric?, hook: UsageMetric, desktop: UsageMetric? = nil) -> UsageMetric {
        let official = mergeOfficial(api: api, hook: hook)
        guard let desktop, desktop.usedPercent != nil || desktop.weeklyPercent != nil,
              let desktopAt = desktop.measuredAt else { return official }
        if official.usedPercent != nil || official.weeklyPercent != nil,
           let officialAt = official.measuredAt, officialAt >= desktopAt {
            return official
        }
        return UsageMetric(
            provider: .claudeCode,
            usedPercent: desktop.usedPercent,
            weeklyPercent: desktop.weeklyPercent,
            primaryWindowDurationMins: desktop.primaryWindowDurationMins,
            secondaryWindowDurationMins: desktop.secondaryWindowDurationMins,
            contextWindowPercent: hook.contextWindowPercent,
            costTodayUSD: hook.costTodayUSD,
            dataSource: desktop.dataSource,
            measuredAt: desktopAt
        )
    }

    private static func mergeOfficial(api: UsageMetric?, hook: UsageMetric) -> UsageMetric {
        guard let api, api.usedPercent != nil || api.weeklyPercent != nil else { return hook }
        if hook.usedPercent != nil, let hookAt = hook.measuredAt, let apiAt = api.measuredAt, hookAt > apiAt {
            return hook
        }
        return UsageMetric(
            provider: .claudeCode,
            usedPercent: api.usedPercent,
            weeklyPercent: api.weeklyPercent,
            primaryWindowDurationMins: api.primaryWindowDurationMins,
            secondaryWindowDurationMins: api.secondaryWindowDurationMins,
            contextWindowPercent: hook.contextWindowPercent,
            costTodayUSD: hook.costTodayUSD,
            resetDate: api.resetDate,
            weeklyResetDate: api.weeklyResetDate,
            dataSource: .officialQuota,
            measuredAt: api.measuredAt
        )
    }

    // `resets_at` carries microseconds ("…T11:00:00.256519+00:00") or none.
    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        // Trim sub-millisecond digits for formatters that only take three.
        if let dot = string.firstIndex(of: "."),
           let zone = string[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = string[string.index(after: dot)..<zone].prefix(3)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string[..<dot] + "." + fraction + string[zone...])
        }
        return nil
    }
}

#if os(macOS)
/// Polls the Claude usage endpoint with the OAuth token Claude Code keeps in
/// the login Keychain (`Claude Code-credentials`).
///
/// Never refreshes the token itself: refresh tokens rotate, so doing it here
/// could sign Claude Code out. An expired token just waits until Claude Code
/// next runs and refreshes it.
///
/// The endpoint rate-limits aggressively (30–60s polling gets stuck on 429 for
/// hours, which also breaks Claude Code's own `/usage`), so polling follows
/// local Claude activity: transcripts under `~/.claude/projects` are written
/// by every Claude Code surface, terminal and IDE alike.
public final class ClaudeUsageAPIClient: @unchecked Sendable {
    public typealias UpdateHandler = @Sendable () -> Void

    public enum CredentialState: Sendable {
        case unknown
        case valid
        /// Only Claude Code refreshes it, so using just the Claude app
        /// leaves it expired.
        case expired
        case missing
        case denied
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    /// Minimum spacing while transcripts show new Claude activity.
    static let activeInterval: TimeInterval = 300
    /// Spacing when nothing changed locally (usage from claude.ai or other devices).
    static let idleInterval: TimeInterval = 900
    /// Local hours [2, 8) poll this many times less often.
    static let quietHours = 2..<8
    static let quietHoursFactor: Double = 2
    private static let backoffSeconds: [TimeInterval] = [300, 900, 1800, 3600]
    /// Checking for Claude Code's refresh only reads the item's attributes.
    private static let expiredTokenRetry: TimeInterval = 60
    private static let deniedRetry: TimeInterval = 3600
    /// `security` exits with the low byte of the OSStatus.
    private static let securityNotFoundStatus: Int32 = 44  // errSecItemNotFound
    private static let securityDeniedStatuses: Set<Int32> = [
        128,  // errSecUserCanceled
        51,   // errSecAuthFailed
        36,   // errSecInteractionNotAllowed
    ]

    private let queue = DispatchQueue(label: "org.tobywu.pelu.claude-usage", qos: .utility)
    private let userAgent: String
    private let session: URLSession

    // Owned by `queue`, which may block on a Keychain prompt.
    private var token: (value: String, expiresAt: Date?)?
    /// Item modification date when `token` was read; unchanged means
    /// re-reading would return the same token.
    private var tokenItemModifiedAt: Date?
    private var nextAttemptAt = Date.distantPast
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0
    private var hasSucceeded = false
    private var isInFlight = false
    /// Behind a lock rather than `queue` so readers never wait on a prompt.
    private let latestLock = NSLock()
    private var latest: (data: Data, fetchedAt: Date)?
    private var _credentialState = CredentialState.unknown

    public var onUpdate: UpdateHandler?

    public var credentialState: CredentialState {
        latestLock.withLock { _credentialState }
    }

    public init(clientVersion: String) {
        userAgent = "Pelu/\(clientVersion)"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    /// Latest response parsed against `now`, or nil before the first success.
    public func latestMetric(now: Date = Date()) -> UsageMetric? {
        guard let latest = latestLock.withLock({ latest }) else { return nil }
        return try? ClaudeUsageAPIParser().parse(data: latest.data, fetchedAt: latest.fetchedAt, generatedAt: now)
    }

    /// Cheap to call on every refresh; fetches only when `isDue` says so.
    public func refreshIfDue() {
        queue.async { [weak self] in
            guard let self, !self.isInFlight else { return }
            let now = Date()
            guard Self.isDue(
                now: now,
                nextAttemptAt: self.nextAttemptAt,
                lastAttemptAt: self.lastAttemptAt,
                lastActivityAt: Self.latestTranscriptActivity()
            ) else { return }
            guard let token = self.currentToken() else {
                let retry = self.credentialState == .denied ? Self.deniedRetry : Self.expiredTokenRetry
                self.nextAttemptAt = now.addingTimeInterval(retry)
                return
            }
            self.isInFlight = true
            self.lastAttemptAt = now
            self.fetch(token: token)
        }
    }

    /// `nextAttemptAt` only carries failure backoff. Past it, fetch once the
    /// active interval has elapsed if Claude ran since the last attempt, else
    /// once the idle interval has; both stretch during quiet hours.
    static func isDue(
        now: Date, nextAttemptAt: Date, lastAttemptAt: Date?, lastActivityAt: Date?,
        activeInterval: TimeInterval = ClaudeUsageAPIClient.activeInterval,
        idleInterval: TimeInterval = ClaudeUsageAPIClient.idleInterval,
        calendar: Calendar = .current
    ) -> Bool {
        guard now >= nextAttemptAt else { return false }
        guard let lastAttemptAt else { return true }
        let factor = quietHours.contains(calendar.component(.hour, from: now)) ? quietHoursFactor : 1
        let hasNewActivity = lastActivityAt.map { $0 > lastAttemptAt } ?? false
        let interval = (hasNewActivity ? activeInterval : idleInterval) * factor
        return now.timeIntervalSince(lastAttemptAt) >= interval
    }

    /// Newest mtime among `~/.claude/projects/*/*.jsonl` (a few dozen files).
    private static func latestTranscriptActivity() -> Date? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        var latest: Date?
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let date = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
                if latest.map({ date > $0 }) ?? true { latest = date }
            }
        }
        return latest
    }

    private func fetch(token: String) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.queue.async {
                self.isInFlight = false
                let now = Date()
                if status == 200, let data,
                   (try? ClaudeUsageAPIParser().parse(data: data, fetchedAt: now, generatedAt: now)) != nil {
                    self.latestLock.withLock { self.latest = (data, now) }
                    if !self.hasSucceeded || self.consecutiveFailures > 0 {
                        NSLog("Pelu Claude usage API OK after \(self.consecutiveFailures) failure(s)")
                    }
                    self.hasSucceeded = true
                    self.consecutiveFailures = 0
                    self.nextAttemptAt = .distantPast
                    self.onUpdate?()
                    return
                }
                // 401: Claude Code probably rotated the token; re-read it next time.
                if status == 401 { self.token = nil }
                self.consecutiveFailures += 1
                let delay = Self.backoffSeconds[min(self.consecutiveFailures, Self.backoffSeconds.count) - 1]
                self.nextAttemptAt = now.addingTimeInterval(delay)
                NSLog("Pelu Claude usage API failed (HTTP \(status), \(error?.localizedDescription ?? "-")), retry in \(Int(delay))s")
            }
        }.resume()
    }

    /// Re-reads the token only when the Keychain item changed (Claude Code
    /// rewrites it on refresh) or there is no usable cached one.
    private func currentToken() -> String? {
        let now = Date()
        let itemModifiedAt = Self.keychainItemModifiedAt()
        let cachedExpired = token?.expiresAt.map { $0 <= now } ?? false
        // Without a Keychain item (file fallback) there is no change signal.
        if token == nil || itemModifiedAt != tokenItemModifiedAt || (cachedExpired && itemModifiedAt == nil) {
            switch readCredentials() {
            case .found(let credentials):
                token = credentials
                tokenItemModifiedAt = itemModifiedAt
            case .missing:
                token = nil
                setCredentialState(.missing)
                return nil
            case .denied:
                token = nil
                setCredentialState(.denied)
                return nil
            }
        }
        guard let token, token.expiresAt.map({ $0 > now }) ?? true else {
            setCredentialState(.expired)
            return nil
        }
        setCredentialState(.valid)
        return token.value
    }

    private func setCredentialState(_ state: CredentialState) {
        let changed = latestLock.withLock {
            defer { _credentialState = state }
            return _credentialState != state
        }
        if changed { NSLog("Pelu Claude usage API: credentials \(state)") }
    }

    private enum CredentialRead {
        case found((value: String, expiresAt: Date?))
        case missing
        case denied
    }

    /// Reads through `/usr/bin/security` rather than `SecItemCopyMatching`:
    /// Claude Code writes the item with that tool, which keeps it trusted,
    /// while every Claude Code rewrite drops Pelu's own access and makes
    /// macOS ask for the login password again.
    private func readCredentials() -> CredentialRead {
        let result = Self.runSecurity(["find-generic-password", "-s", Self.keychainService, "-w"])
        var data: Data?
        switch result?.status {
        case 0:
            data = result?.output
        case let status? where Self.securityDeniedStatuses.contains(status):
            NSLog("Pelu Claude usage API: Keychain access denied (security exit \(status)), retry in \(Int(Self.deniedRetry))s")
            return .denied
        case nil:
            NSLog("Pelu Claude usage API: security did not finish, retry in \(Int(Self.deniedRetry))s")
            return .denied
        default:
            if result?.status != Self.securityNotFoundStatus {
                NSLog("Pelu Claude usage API: security exit \(result?.status ?? -1), trying credentials file")
            }
            // Some installs keep credentials in a file instead of the Keychain.
            data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json"))
        }
        guard let data, let credentials = Self.parseCredentials(data) else { return .missing }
        return .found(credentials)
    }

    /// Accepts the credentials JSON, or its hex form (what `security -w`
    /// prints for data that isn't plain text).
    static func parseCredentials(_ data: Data) -> (value: String, expiresAt: Date?)? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let json = text.hasPrefix("{") ? Data(text.utf8) : hexDecoded(text)
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let value = oauth["accessToken"] as? String, !value.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (value, expiresAt)
    }

    private static func hexDecoded(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    /// Attributes are readable without the item's ACL, so this never prompts.
    private static func keychainItemModifiedAt() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    /// Nil when it can't launch or is still running after `timeout` (an
    /// unanswered prompt). The output is a few KB, well under the pipe buffer.
    private static func runSecurity(_ arguments: [String], timeout: TimeInterval = 60) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, output)
    }
}
#endif // os(macOS)
