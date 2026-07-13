import AIUsageBarCore
import Darwin
import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum CoreTestRunner {
    static func main() async throws {
        typealias AsyncTest = () async throws -> Void
        var tests: [(String, AsyncTest)] = [
            ("Codex uses the Usage screen payload as source of truth", { try testCodexUsageScreenParsing() }),
            ("Codex client requests the Usage screen endpoint", { try await testCodexUsageScreenClient() }),
            ("Claude utilization remains on the provider's 0-100 scale", { try testClaudeParsing() }),
            ("Claude client reuses Keychain credentials across refreshes", { try await testClaudeCredentialReuse() }),
            ("Claude client throttles repeated usage refreshes", { try await testClaudeRefreshThrottle() }),
            ("Claude client coalesces concurrent usage refreshes", { try await testClaudeConcurrentRefreshes() }),
            ("Claude client keeps the last snapshot while rate limited", { try await testClaudeRateLimitFallback() }),
            ("Claude client honors delta-seconds Retry-After", { try await testClaudeDeltaSecondsRetryAfter() }),
            ("Claude client starts delta-seconds backoff at response time", { try await testClaudeBackoffStartsAtResponse() }),
            ("Claude client does not return a snapshot that resets in flight", { try await testClaudeSnapshotResetInFlight() }),
            ("Claude client honors HTTP-date Retry-After", { try await testClaudeHTTPDateRetryAfter() }),
            ("Claude client restores the last snapshot after restart", { try await testClaudeSnapshotPersistence() }),
            ("Claude client expires snapshots without a reset time", { try await testClaudeSnapshotWithoutResetExpires() }),
            ("Usage snapshot store persists provider data only", { try testUsageSnapshotStore() }),
            ("Claude client does not repeat a denied Keychain read", { try await testClaudeCredentialDenial() }),
            ("Claude client does not repeat an invalid Keychain read", { try await testClaudeInvalidCredential() }),
            ("Percentages clamp", { try testClamping() }),
            ("Codex local tokens use the requested window", { try testCodexTokens() }),
            ("Claude local tokens de-duplicate messages", { try testClaudeTokens() }),
            ("Oversized prompt records do not break token scanning", { try testOversizedRecord() }),
            ("Settings and language persist", { try testSettings() }),
        ]
        if ProcessInfo.processInfo.environment["AIUSAGEBAR_LIVE_TESTS"] == "1" {
            tests.append(("Live Codex Usage screen endpoint returns weekly usage", { try await testLiveCodex() }))
        }

        var failures: [String] = []
        for (name, test) in tests {
            do {
                try await test()
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

    private static func testCodexUsageScreenParsing() throws {
        let json = #"{"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1784512550},"secondary_window":null}}"#
        let snapshot = try CodexUsageScreenParser.parse(data: Data(json.utf8))
        try expect(snapshot.provider == .codex, "provider")
        try expect(snapshot.weekly.usedPercent == 21, "Usage screen used percent")
        try expect(snapshot.weekly.remainingPercent == 79, "Usage screen remaining percent")
        try expect(snapshot.weekly.durationMinutes == 10_080, "weekly duration")
    }

    private static func testCodexUsageScreenClient() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCodexUsageURLProtocol.self]
        let client = CodexUsageClient(
            credentialReader: MockCodexCredentialReader(),
            session: URLSession(configuration: configuration)
        )
        let snapshot = try await client.fetch()
        try expect(snapshot.weekly.usedPercent == 21, "client used percent")
        try expect(snapshot.weekly.remainingPercent == 79, "client remaining percent")
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

    private static func testClaudeCredentialReuse() async throws {
        MockClaudeUsageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let credentialReader = CountingClaudeCredentialReader { _ in
            ClaudeCredential(accessToken: "test-token", expiresAt: nil)
        }
        let client = ClaudeUsageClient(
            credentialReader: credentialReader,
            session: URLSession(configuration: configuration),
            snapshotStore: TestUsageSnapshotStore()
        )

        _ = try await client.fetch()
        _ = try await client.fetch()

        try expect(
            credentialReader.readCount == 1,
            "two automatic refreshes should access Keychain once, got \(credentialReader.readCount)"
        )
    }

    private static func testClaudeRefreshThrottle() async throws {
        MockClaudeUsageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            minimumFetchInterval: 300,
            snapshotStore: TestUsageSnapshotStore()
        )

        let first = try await client.fetch()
        let second = try await client.fetch()

        try expect(first == second, "throttled refresh should return the last successful snapshot")
        try expect(MockClaudeUsageURLProtocol.requestCount == 1, "two immediate refreshes should make one request")
    }

    private static func testClaudeConcurrentRefreshes() async throws {
        MockClaudeUsageURLProtocol.reset(responseDelay: 0.1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            snapshotStore: TestUsageSnapshotStore()
        )

        async let first = client.fetch()
        async let second = client.fetch()
        let snapshots = try await [first, second]

        try expect(snapshots[0] == snapshots[1], "concurrent refreshes should share one result")
        try expect(MockClaudeUsageURLProtocol.requestCount == 1, "concurrent refreshes should make one request")
    }

    private static func testClaudeRateLimitFallback() async throws {
        MockClaudeUsageURLProtocol.reset(statusCodes: [200, 429, 200])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_784_000_000))
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            minimumFetchInterval: 300,
            now: { clock.date },
            snapshotStore: TestUsageSnapshotStore()
        )

        let first = try await client.fetch()
        clock.advance(by: 301)
        let rateLimited = try await client.fetch()
        let backedOff = try await client.fetch()

        try expect(rateLimited == first, "429 should preserve the last successful snapshot")
        try expect(backedOff == first, "backoff should keep returning the last successful snapshot")
        try expect(MockClaudeUsageURLProtocol.requestCount == 2, "backoff should suppress a third request")
    }

    private static func testClaudeDeltaSecondsRetryAfter() async throws {
        try await assertClaudeRetryAfter("1200")
    }

    private static func testClaudeBackoffStartsAtResponse() async throws {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let clock = TestClock(date: start)
        MockClaudeUsageURLProtocol.reset(
            statusCodes: [200, 429, 200],
            retryAfter: "300",
            responseHook: { statusCode in
                if statusCode == 429 {
                    clock.advance(by: 10)
                }
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            minimumFetchInterval: 0,
            now: { clock.date },
            snapshotStore: TestUsageSnapshotStore()
        )

        _ = try await client.fetch()
        clock.advance(by: 1)
        _ = try await client.fetch()
        clock.advance(by: 295)
        _ = try await client.fetch()

        try expect(MockClaudeUsageURLProtocol.requestCount == 2, "delta-seconds should begin when 429 arrives")
    }

    private static func testClaudeSnapshotResetInFlight() async throws {
        let resetAt = try require(
            ISO8601DateFormatter().date(from: "2026-07-20T08:00:00Z"),
            "Claude reset time"
        )
        let clock = TestClock(date: resetAt.addingTimeInterval(-10))
        MockClaudeUsageURLProtocol.reset(
            statusCodes: [200, 429],
            responseHook: { statusCode in
                if statusCode == 429 {
                    clock.advance(by: 20)
                }
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            minimumFetchInterval: 0,
            now: { clock.date },
            snapshotStore: TestUsageSnapshotStore()
        )

        _ = try await client.fetch()
        do {
            _ = try await client.fetch()
            throw TestFailure(description: "snapshot crossing its reset time should not be returned")
        } catch ProviderClientError.claudeUnavailable {
            // Expected: the last snapshot expired while the rate-limited request was in flight.
        }
    }

    private static func testClaudeHTTPDateRetryAfter() async throws {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        let retryAfter = formatter.string(from: start.addingTimeInterval(1_200))
        try await assertClaudeRetryAfter(retryAfter, start: start)
    }

    private static func assertClaudeRetryAfter(
        _ retryAfter: String,
        start: Date = Date(timeIntervalSince1970: 1_784_000_000)
    ) async throws {
        MockClaudeUsageURLProtocol.reset(statusCodes: [200, 429, 200], retryAfter: retryAfter)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let clock = TestClock(date: start)
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            minimumFetchInterval: 300,
            now: { clock.date },
            snapshotStore: TestUsageSnapshotStore()
        )

        _ = try await client.fetch()
        clock.advance(by: 301)
        _ = try await client.fetch()
        clock.advance(by: 600)
        _ = try await client.fetch()

        try expect(MockClaudeUsageURLProtocol.requestCount == 2, "Retry-After should suppress early retry")
    }

    private static func testClaudeSnapshotPersistence() async throws {
        MockClaudeUsageURLProtocol.reset(statusCodes: [200, 429])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = TestClock(date: Date(timeIntervalSince1970: 1_784_000_000))
        let snapshotStore = TestUsageSnapshotStore()
        let credentialReader = CountingClaudeCredentialReader { _ in
            ClaudeCredential(accessToken: "test-token", expiresAt: nil)
        }

        let firstClient = ClaudeUsageClient(
            credentialReader: credentialReader,
            session: session,
            minimumFetchInterval: 300,
            now: { clock.date },
            snapshotStore: snapshotStore
        )
        let first = try await firstClient.fetch()

        clock.advance(by: 301)
        let restartedClient = ClaudeUsageClient(
            credentialReader: credentialReader,
            session: session,
            minimumFetchInterval: 300,
            now: { clock.date },
            snapshotStore: snapshotStore
        )
        let restored = try await restartedClient.fetch()

        let restartedDuringBackoff = ClaudeUsageClient(
            credentialReader: credentialReader,
            session: session,
            minimumFetchInterval: 300,
            now: { clock.date },
            snapshotStore: snapshotStore
        )
        let backedOffAfterRestart = try await restartedDuringBackoff.fetch()

        try expect(restored == first, "restart during 429 should restore the last successful snapshot")
        try expect(backedOffAfterRestart == first, "persisted backoff should keep the last snapshot")
        try expect(MockClaudeUsageURLProtocol.requestCount == 2, "restart during backoff should not request again")
    }

    private static func testUsageSnapshotStore() throws {
        let suite = "AIUsageBarSnapshotTests.\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite), "snapshot defaults")
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = UsageSnapshot(
            provider: .claude,
            weekly: UsageWindow(
                usedPercent: 42,
                resetAt: Date(timeIntervalSince1970: 1_784_512_000),
                durationMinutes: 10_080
            ),
            fetchedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )

        let retryAt = Date(timeIntervalSince1970: 1_784_000_900)
        UserDefaultsUsageSnapshotStore(defaults: defaults).save(snapshot)
        UserDefaultsUsageSnapshotStore(defaults: defaults).saveNextAllowedRequestAt(retryAt, provider: .claude)
        let reloadedStore = UserDefaultsUsageSnapshotStore(defaults: defaults)
        let restored = reloadedStore.load(provider: .claude)

        try expect(restored == snapshot, "stored provider snapshot should round-trip")
        try expect(
            reloadedStore.loadNextAllowedRequestAt(provider: .claude) == retryAt,
            "stored rate-limit backoff should round-trip"
        )
    }

    private static func testClaudeSnapshotWithoutResetExpires() async throws {
        let start = Date(timeIntervalSince1970: 1_784_000_000)
        let snapshotStore = TestUsageSnapshotStore()
        snapshotStore.save(
            UsageSnapshot(
                provider: .claude,
                weekly: UsageWindow(usedPercent: 42, resetAt: nil, durationMinutes: 10_080),
                fetchedAt: start
            )
        )
        MockClaudeUsageURLProtocol.reset(statusCodes: [429])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let clock = TestClock(date: start.addingTimeInterval(25 * 60 * 60))
        let client = ClaudeUsageClient(
            credentialReader: CountingClaudeCredentialReader { _ in
                ClaudeCredential(accessToken: "test-token", expiresAt: nil)
            },
            session: URLSession(configuration: configuration),
            now: { clock.date },
            snapshotStore: snapshotStore
        )

        do {
            _ = try await client.fetch()
            throw TestFailure(description: "snapshot without reset time should expire after 24 hours")
        } catch ProviderClientError.claudeUnavailable {
            // Expected: the server is limited and the old snapshot is no longer safe to show.
        }
        try expect(MockClaudeUsageURLProtocol.requestCount == 1, "expired snapshot should attempt a fresh request")
    }

    private static func testClaudeCredentialDenial() async throws {
        let credentialReader = CountingClaudeCredentialReader { _ in
            throw ProviderClientError.claudeCredentialMissing
        }
        let client = ClaudeUsageClient(
            credentialReader: credentialReader,
            snapshotStore: TestUsageSnapshotStore()
        )

        for _ in 0 ..< 2 {
            do {
                _ = try await client.fetch()
                throw TestFailure(description: "denied credential read should fail")
            } catch ProviderClientError.claudeCredentialMissing {
                // Expected.
            }
        }
        try expect(credentialReader.readCount == 1, "denied Keychain access should not be retried automatically")

        client.reloadCredentialOnNextFetch()
        do {
            _ = try await client.fetch()
            throw TestFailure(description: "reloaded denied credential read should fail")
        } catch ProviderClientError.claudeCredentialMissing {
            // Expected.
        }
        try expect(credentialReader.readCount == 2, "explicit reload should permit one new Keychain read")
    }

    private static func testClaudeInvalidCredential() async throws {
        MockClaudeUsageURLProtocol.reset()
        let credentialReader = CountingClaudeCredentialReader { readNumber in
            if readNumber == 1 {
                throw TestFailure(description: "invalid credential JSON")
            }
            return ClaudeCredential(accessToken: "test-token", expiresAt: nil)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockClaudeUsageURLProtocol.self]
        let client = ClaudeUsageClient(
            credentialReader: credentialReader,
            session: URLSession(configuration: configuration),
            snapshotStore: TestUsageSnapshotStore()
        )

        for _ in 0 ..< 2 {
            do {
                _ = try await client.fetch()
                throw TestFailure(description: "invalid credential should fail")
            } catch ProviderClientError.claudeCredentialInvalid {
                // Expected.
            }
        }
        try expect(credentialReader.readCount == 1, "invalid Keychain data should not be reread automatically")

        client.reloadCredentialOnNextFetch()
        let snapshot = try await client.fetch()
        try expect(credentialReader.readCount == 2, "explicit reload should reread corrected Keychain data")
        try expect(snapshot.weekly.usedPercent == 0.42, "explicit reload should recover Claude usage")
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

    private static func testLiveCodex() async throws {
        let snapshot = try await CodexUsageClient().fetch()
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

private struct MockCodexCredentialReader: CodexCredentialReading {
    func read() throws -> CodexCredential {
        CodexCredential(accessToken: "test-token", accountID: "test-account")
    }
}

private final class CountingClaudeCredentialReader: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private let readCredential: @Sendable (Int) throws -> ClaudeCredential
    private var count = 0

    init(readCredential: @escaping @Sendable (Int) throws -> ClaudeCredential) {
        self.readCredential = readCredential
    }

    var readCount: Int {
        lock.withLock { count }
    }

    func read() throws -> ClaudeCredential {
        let readNumber = lock.withLock {
            count += 1
            return count
        }
        return try readCredential(readNumber)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date

    init(date: Date) {
        currentDate = date
    }

    var date: Date {
        lock.withLock { currentDate }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { currentDate = currentDate.addingTimeInterval(interval) }
    }
}

private final class TestUsageSnapshotStore: UsageSnapshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: UsageSnapshot?
    private var nextAllowedRequestAt: Date?

    func load(provider: ProviderID) -> UsageSnapshot? {
        lock.withLock { snapshot?.provider == provider ? snapshot : nil }
    }

    func save(_ snapshot: UsageSnapshot) {
        lock.withLock { self.snapshot = snapshot }
    }

    func loadNextAllowedRequestAt(provider: ProviderID) -> Date? {
        lock.withLock { nextAllowedRequestAt }
    }

    func saveNextAllowedRequestAt(_ date: Date?, provider: ProviderID) {
        lock.withLock { nextAllowedRequestAt = date }
    }
}

private final class MockCodexUsageURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isCorrectRequest = request.url?.host == "chatgpt.com"
            && request.url?.path == "/backend-api/wham/usage"
            && queryItems.contains(URLQueryItem(name: "supports_rewardless_invites", value: "true"))
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
            && request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "test-account"
        let statusCode = isCorrectRequest ? 200 : 400
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":604800,"reset_at":1784512550},"secondary_window":null}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MockClaudeUsageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var count = 0
    private nonisolated(unsafe) static var statusCodes = [200]
    private nonisolated(unsafe) static var responseDelay: TimeInterval = 0
    private nonisolated(unsafe) static var retryAfter = "0"
    private nonisolated(unsafe) static var responseHook: (@Sendable (Int) -> Void)?

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset(
        statusCodes newStatusCodes: [Int] = [200],
        responseDelay newResponseDelay: TimeInterval = 0,
        retryAfter newRetryAfter: String = "0",
        responseHook newResponseHook: (@Sendable (Int) -> Void)? = nil
    ) {
        lock.withLock {
            count = 0
            statusCodes = newStatusCodes
            responseDelay = newResponseDelay
            retryAfter = newRetryAfter
            responseHook = newResponseHook
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (scriptedStatusCode, responseDelay, retryAfter, responseHook) = Self.lock.withLock {
            Self.count += 1
            if Self.statusCodes.count > 1 {
                return (Self.statusCodes.removeFirst(), Self.responseDelay, Self.retryAfter, Self.responseHook)
            }
            return (Self.statusCodes.first ?? 200, Self.responseDelay, Self.retryAfter, Self.responseHook)
        }
        let isCorrectRequest = request.url?.host == "api.anthropic.com"
            && request.url?.path == "/api/oauth/usage"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        let statusCode = isCorrectRequest ? scriptedStatusCode : 400
        let payload = statusCode == 429
            ? #"{"error":{"type":"rate_limit_error","message":"Rate limited. Please try again later."}}"#
            : #"{"seven_day":{"utilization":0.42,"resets_at":"2026-07-20T08:00:00Z"}}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Retry-After": retryAfter]
        )!
        let respond = { [self] in
            responseHook?(statusCode)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if responseDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + responseDelay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}
