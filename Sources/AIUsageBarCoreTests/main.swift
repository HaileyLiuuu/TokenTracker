import AIUsageBarCore
import Darwin
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum CoreTestRunner {
    static func main() throws {
        var tests: [(String, () throws -> Void)] = [
            ("Codex weekly response normalizes", testCodexParsing),
            ("Claude utilization remains on the provider's 0-100 scale", testClaudeParsing),
            ("Percentages clamp", testClamping),
            ("Codex local tokens use the requested window", testCodexTokens),
            ("Claude local tokens de-duplicate messages", testClaudeTokens),
            ("Oversized prompt records do not break token scanning", testOversizedRecord),
            ("Settings and language persist", testSettings),
        ]
        if ProcessInfo.processInfo.environment["AIUSAGEBAR_LIVE_TESTS"] == "1" {
            tests.append(("Live Codex app-server returns weekly usage", testLiveCodex))
        }

        var failures: [String] = []
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures.append("✗ \(name): \(error)")
            }
        }

        if !failures.isEmpty {
            failures.forEach { print($0) }
            fflush(stdout)
            exit(1)
        }
        print("\n\(tests.count) tests passed")
    }

    private static func testCodexParsing() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784512550},"secondary":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1784512550}}}}}"#
        guard let snapshot = try CodexRateLimitParser.parse(line: json) else {
            throw TestFailure(description: "No snapshot")
        }
        try expect(snapshot.provider == .codex, "provider")
        try expect(snapshot.weekly.usedPercent == 17, "used percent")
        try expect(snapshot.weekly.remainingPercent == 83, "remaining percent")
        try expect(snapshot.weekly.durationMinutes == 10_080, "duration")
        try expect(snapshot.weekly.resetAt == Date(timeIntervalSince1970: 1_784_512_550), "reset")
    }

    private static func testClaudeParsing() throws {
        let json = #"{"five_hour":{"utilization":0.11,"resets_at":"2026-07-13T10:00:00Z"},"seven_day":{"utilization":0.42,"resets_at":"2026-07-20T08:00:00Z"}}"#
        let snapshot = try ClaudeUsageParser.parse(data: Data(json.utf8))
        try expect(snapshot.provider == .claude, "provider")
        try expect(snapshot.weekly.usedPercent == 0.42, "used percent")
        try expect(snapshot.weekly.remainingPercent == 99.58, "remaining percent")
        try expect(snapshot.weekly.durationMinutes == 10_080, "duration")
        try expect(snapshot.weekly.resetAt == ISO8601DateFormatter().date(from: "2026-07-20T08:00:00Z"), "reset")
    }

    private static func testClamping() throws {
        let below = UsageWindow(usedPercent: -4, resetAt: nil, durationMinutes: nil)
        let above = UsageWindow(usedPercent: 108, resetAt: nil, durationMinutes: nil)
        try expect(below.usedPercent == 0 && below.remainingPercent == 100, "lower clamp")
        try expect(above.usedPercent == 100 && above.remainingPercent == 0, "upper clamp")
    }

    private static func testCodexTokens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = [
            #"{"timestamp":"2026-07-05T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1000}}}}"#,
            #"{"timestamp":"2026-07-10T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":2500}}}}"#,
            #"{"timestamp":"2026-07-11T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":3500}}}}"#,
        ].joined(separator: "\n")
        try contents.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let cutoff = try require(ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z"), "cutoff")
        try expect(LocalTokenScanner.codexTokens(in: [directory], since: cutoff) == 6_000, "token total")
    }

    private static func testClaudeTokens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = #"{"timestamp":"2026-07-10T12:00:00Z","type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}"#
        let contents = [
            #"{"timestamp":"2026-07-05T12:00:00Z","type":"assistant","message":{"id":"old","usage":{"input_tokens":999,"output_tokens":1}}}"#,
            message,
            message,
            #"{"timestamp":"2026-07-11T12:00:00Z","type":"assistant","message":{"id":"msg_2","usage":{"input_tokens":5,"output_tokens":5}}}"#,
        ].joined(separator: "\n")
        try contents.write(to: directory.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let cutoff = try require(ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z"), "cutoff")
        try expect(LocalTokenScanner.claudeTokens(in: [directory], since: cutoff) == 110, "token total")
    }

    private static func testOversizedRecord() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversizedPrompt = #"{"timestamp":"2026-07-10T12:00:00Z","type":"user","message":""#
            + String(repeating: "x", count: 8 * 1_024 * 1_024)
            + #""}"#
        let tokenEvent = #"{"timestamp":"2026-07-11T12:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":321}}}}"#
        let contents = oversizedPrompt + "\n" + tokenEvent
        try contents.write(to: directory.appendingPathComponent("large-session.jsonl"), atomically: true, encoding: .utf8)
        let cutoff = try require(ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z"), "cutoff")
        try expect(LocalTokenScanner.codexTokens(in: [directory], since: cutoff) == 321, "scanner recovery")
    }

    private static func testSettings() throws {
        let suite = "AIUsageBarTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "defaults")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.primaryProvider = .claude
        store.language = .english
        let reloaded = SettingsStore(defaults: defaults)
        try expect(reloaded.primaryProvider == .claude, "primary provider")
        try expect(reloaded.language == .english, "language")
        try expect(reloaded.language.text(.remaining) == "Remaining", "English label")
        try expect(AppLanguage.chinese.text(.remaining) == "剩余", "Chinese label")
    }

    private static func testLiveCodex() throws {
        let snapshot = try CodexUsageClient().fetch()
        try expect(snapshot.weekly.durationMinutes == 10_080, "weekly duration")
        try expect((0 ... 100).contains(snapshot.weekly.usedPercent), "valid percent")
        try expect(snapshot.weekly.resetAt != nil, "reset time")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(description: message) }
        return value
    }
}
