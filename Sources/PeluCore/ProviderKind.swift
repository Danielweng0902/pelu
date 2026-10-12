import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case claudeCode = "claude_code"
    case codex
    case cursor
    case grokBot = "grok_bot"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode:
            "Claude Code"
        case .codex:
            "Codex"
        case .cursor:
            "Cursor"
        case .grokBot:
            "Grok Bot"
        }
    }

    public var shortName: String {
        switch self {
        case .claudeCode:
            "Claude"
        case .codex:
            "Codex"
        case .cursor:
            "Cursor"
        case .grokBot:
            "GrokBot"
        }
    }

    /// Single letter for the menu bar, in text and ring styles alike.
    public var menuBarLetter: String {
        switch self {
        case .claudeCode:
            "C"
        case .codex:
            "X"
        case .cursor:
            "U"
        case .grokBot:
            "G"
        }
    }

    public var assetName: String {
        switch self {
        case .claudeCode:
            "ClaudeIcon"
        case .codex:
            "CodexIcon"
        case .cursor:
            "CursorIcon"
        case .grokBot:
            "GrokBotIcon"
        }
    }

    /// iOS 1.1 and earlier decode the CloudKit `payload` as a strict
    /// `[UsageMetric]`, so an unknown provider there would drop the whole
    /// Mac. Every other provider travels in `extraMetrics`.
    public var fitsLegacyPayload: Bool {
        self == .claudeCode || self == .codex
    }

    /// Grok Bot has a single weekly pool.
    public var hasSecondaryWindow: Bool {
        self != .grokBot
    }
}
