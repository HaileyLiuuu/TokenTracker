import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetAt: Date?
    public let durationMinutes: Int?

    public init(usedPercent: Double, resetAt: Date?, durationMinutes: Int?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
        self.durationMinutes = durationMinutes
    }

    public var remainingPercent: Double {
        100 - usedPercent
    }

    public var startsAt: Date? {
        guard let resetAt, let durationMinutes else { return nil }
        return resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let provider: ProviderID
    public let weekly: UsageWindow
    public let fetchedAt: Date

    public init(
        provider: ProviderID,
        weekly: UsageWindow,
        fetchedAt: Date = Date()
    ) {
        self.provider = provider
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }
}
