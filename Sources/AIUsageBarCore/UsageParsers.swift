import Foundation

public enum UsageParsingError: LocalizedError {
    case missingCodexUsageScreenWeeklyWindow
    case missingClaudeWeeklyWindow

    public var errorDescription: String? {
        switch self {
        case .missingCodexUsageScreenWeeklyWindow:
            "The Codex Usage screen did not return a weekly usage window."
        case .missingClaudeWeeklyWindow:
            "Claude Code did not return a weekly usage window."
        }
    }
}

public enum CodexUsageScreenParser {
    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(CodexUsageScreenPayload.self, from: data)
        let candidates = [
            payload.rateLimit.primaryWindow,
            payload.rateLimit.secondaryWindow,
        ].compactMap { $0 }
        guard let weekly = candidates.max(by: {
            ($0.limitWindowSeconds ?? 0) < ($1.limitWindowSeconds ?? 0)
        }) else {
            throw UsageParsingError.missingCodexUsageScreenWeeklyWindow
        }

        return UsageSnapshot(
            provider: .codex,
            weekly: UsageWindow(
                usedPercent: weekly.usedPercent,
                resetAt: weekly.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                durationMinutes: weekly.limitWindowSeconds.map { $0 / 60 }
            ),
            fetchedAt: fetchedAt
        )
    }
}

public enum ClaudeUsageParser {
    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(ClaudePayload.self, from: data)
        guard let weekly = payload.sevenDay ?? payload.sevenDaySonnet ?? payload.sevenDayOpus else {
            throw UsageParsingError.missingClaudeWeeklyWindow
        }

        return UsageSnapshot(
            provider: .claude,
            weekly: UsageWindow(
                usedPercent: weekly.utilization,
                resetAt: parseISO8601Timestamp(weekly.resetsAt),
                durationMinutes: 10_080
            ),
            fetchedAt: fetchedAt
        )
    }
}

private struct CodexUsageScreenPayload: Decodable {
    let rateLimit: RateLimit

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAt: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }
}

private struct ClaudePayload: Decodable {
    let sevenDay: ClaudeWindow?
    let sevenDaySonnet: ClaudeWindow?
    let sevenDayOpus: ClaudeWindow?

    enum CodingKeys: String, CodingKey {
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
    }
}

private struct ClaudeWindow: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

func parseISO8601Timestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}
