import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    public func text(_ key: TextKey) -> String {
        switch (self, key) {
        case (.chinese, .usage): "用量"
        case (.english, .usage): "Usage"
        case (.chinese, .weeklyUsage): "每周用量"
        case (.english, .weeklyUsage): "Weekly usage"
        case (.chinese, .primaryDisplay): "主显示"
        case (.english, .primaryDisplay): "Primary"
        case (.chinese, .used): "已用"
        case (.english, .used): "Used"
        case (.chinese, .remaining): "剩余"
        case (.english, .remaining): "Remaining"
        case (.chinese, .resets): "下次重置"
        case (.english, .resets): "Resets"
        case (.chinese, .localTokens): "本机 7 天 Token"
        case (.english, .localTokens): "Local 7-day tokens"
        case (.chinese, .lastUpdated): "最后更新"
        case (.english, .lastUpdated): "Updated"
        case (.chinese, .refresh): "立即刷新"
        case (.english, .refresh): "Refresh now"
        case (.chinese, .language): "界面语言"
        case (.english, .language): "Language"
        case (.chinese, .quit): "退出 AIUsageBar"
        case (.english, .quit): "Quit AIUsageBar"
        case (.chinese, .loading): "正在读取…"
        case (.english, .loading): "Loading…"
        case (.chinese, .notAvailable): "暂不可用"
        case (.english, .notAvailable): "Unavailable"
        case (.chinese, .reconnectClaude): "请先在 Claude Code 中重新登录"
        case (.english, .reconnectClaude): "Sign in to Claude Code again"
        case (.chinese, .reconnectCodex): "请先在 Codex 中重新登录"
        case (.english, .reconnectCodex): "Sign in to Codex again"
        case (.chinese, .codexUnavailable): "暂时无法读取 Codex 用量"
        case (.english, .codexUnavailable): "Codex usage is temporarily unavailable"
        case (.chinese, .claudeUnavailable): "暂时无法读取 Claude Code 用量"
        case (.english, .claudeUnavailable): "Claude Code usage is temporarily unavailable"
        case (.chinese, .providerData): "服务官方数据"
        case (.english, .providerData): "Provider data"
        }
    }
}

public enum TextKey: Sendable {
    case usage
    case weeklyUsage
    case primaryDisplay
    case used
    case remaining
    case resets
    case localTokens
    case lastUpdated
    case refresh
    case language
    case quit
    case loading
    case notAvailable
    case reconnectClaude
    case reconnectCodex
    case codexUnavailable
    case claudeUnavailable
    case providerData
}

public final class SettingsStore {
    private enum Key {
        static let primaryProvider = "primaryProvider"
        static let language = "language"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var primaryProvider: ProviderID {
        get { ProviderID(rawValue: defaults.string(forKey: Key.primaryProvider) ?? "") ?? .codex }
        set { defaults.set(newValue.rawValue, forKey: Key.primaryProvider) }
    }

    public var language: AppLanguage {
        get {
            if let stored = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") {
                return stored
            }
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
        }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }
}
