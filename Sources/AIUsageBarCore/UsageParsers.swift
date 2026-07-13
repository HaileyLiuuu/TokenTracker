import Foundation

public enum UsageParsingError: LocalizedError {
    case malformedCodexResponse
    case missingCodexWeeklyWindow
    case missingClaudeWeeklyWindow

    public var errorDescription: String? {
        switch self {
        case .malformedCodexResponse:
            "Codex returned an unreadable usage response."
        case .missingCodexWeeklyWindow:
            "Codex did not return a weekly usage window."
        case .missingClaudeWeeklyWindow:
            "Claude Code did not return a weekly usage window."
        }
    }
}

public enum CodexRateLimitParser {
    public static func parse(line: String, fetchedAt: Date = Date()) throws -> UsageSnapshot? {
        guard let data = line.data(using: .utf8) else {
            throw UsageParsingError.malformedCodexResponse
        }

        let envelope: CodexEnvelope
        do {
            envelope = try JSONDecoder().decode(CodexEnvelope.self, from: data)
        } catch {
            return nil
        }
        guard envelope.id == 2, let result = envelope.result else { return nil }

        let limits = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits
        guard let limits else { throw UsageParsingError.missingCodexWeeklyWindow }
        let candidates = [limits.primary, limits.secondary].compactMap { $0 }
        guard let weekly = candidates.max(by: {
            ($0.windowDurationMins ?? 0) < ($1.windowDurationMins ?? 0)
        }) else {
            throw UsageParsingError.missingCodexWeeklyWindow
        }

        return UsageSnapshot(
            provider: .codex,
            weekly: UsageWindow(
                usedPercent: Double(weekly.usedPercent),
                resetAt: weekly.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                durationMinutes: weekly.windowDurationMins
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

private struct CodexEnvelope: Decodable {
    let id: Int?
    let result: CodexResult?
}

private struct CodexResult: Decodable {
    let rateLimits: CodexLimits?
    let rateLimitsByLimitId: [String: CodexLimits]?
}

private struct CodexLimits: Decodable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
}

private struct CodexWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int?
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
