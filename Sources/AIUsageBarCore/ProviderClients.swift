import Foundation
import Security

public enum ProviderClientError: LocalizedError {
    case codexCredentialMissing
    case codexLoginExpired
    case codexUnavailable(String)
    case claudeCredentialMissing
    case claudeCredentialInvalid
    case claudeLoginExpired
    case claudeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .codexCredentialMissing:
            "Codex is not signed in."
        case .codexLoginExpired:
            "Codex sign-in has expired."
        case let .codexUnavailable(message):
            "Codex usage is unavailable: \(message)"
        case .claudeCredentialMissing:
            "Claude Code is not signed in."
        case .claudeCredentialInvalid:
            "Claude Code credentials are invalid."
        case .claudeLoginExpired:
            "Claude Code sign-in has expired."
        case let .claudeUnavailable(message):
            "Claude Code usage is unavailable: \(message)"
        }
    }
}

public final class CodexUsageClient {
    private let credentialReader: CodexCredentialReading
    private let session: URLSession
    private let endpoint = URL(
        string: "https://chatgpt.com/backend-api/wham/usage?supports_rewardless_invites=true"
    )!

    public init(
        credentialReader: CodexCredentialReading = FileCodexCredentialReader(),
        session: URLSession = .shared
    ) {
        self.credentialReader = credentialReader
        self.session = session
    }

    public func fetch() async throws -> UsageSnapshot {
        let credential = try credentialReader.read()
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("aiusagebar/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.codexUnavailable("invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderClientError.codexLoginExpired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ProviderClientError.codexUnavailable("HTTP \(http.statusCode)")
        }
        return try CodexUsageScreenParser.parse(data: data)
    }
}

public struct CodexCredential: Sendable {
    public let accessToken: String
    public let accountID: String

    public init(accessToken: String, accountID: String) {
        self.accessToken = accessToken
        self.accountID = accountID
    }
}

public protocol CodexCredentialReading: Sendable {
    func read() throws -> CodexCredential
}

public struct FileCodexCredentialReader: CodexCredentialReading {
    private let authFileURL: URL

    public init(authFileURL: URL? = nil) {
        self.authFileURL = authFileURL
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    public func read() throws -> CodexCredential {
        guard let data = try? Data(contentsOf: authFileURL) else {
            throw ProviderClientError.codexCredentialMissing
        }
        let envelope = try JSONDecoder().decode(CodexCredentialEnvelope.self, from: data)
        return CodexCredential(
            accessToken: envelope.tokens.accessToken,
            accountID: envelope.tokens.accountID
        )
    }
}

public final class ClaudeUsageClient: @unchecked Sendable {
    private let credentialReader: ClaudeCredentialReading
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let minimumFetchInterval: TimeInterval
    private let maximumSnapshotAgeWithoutReset: TimeInterval
    private let now: @Sendable () -> Date
    private let snapshotStore: UsageSnapshotStoring
    private let credentialLock = NSLock()
    private var credentialCache: ClaudeCredentialCache = .unread
    private let snapshotLock = NSLock()
    private var lastSnapshot: UsageSnapshot?
    private var lastSuccessfulFetchAt: Date?
    private var nextAllowedRequestAt: Date?
    private let inFlightLock = NSLock()
    private var inFlightFetch: (id: UUID, task: Task<UsageSnapshot, Error>)?

    public init(
        credentialReader: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        session: URLSession = .shared,
        minimumFetchInterval: TimeInterval = 300,
        maximumSnapshotAgeWithoutReset: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        snapshotStore: UsageSnapshotStoring = UserDefaultsUsageSnapshotStore()
    ) {
        self.credentialReader = credentialReader
        self.session = session
        self.minimumFetchInterval = minimumFetchInterval
        self.maximumSnapshotAgeWithoutReset = maximumSnapshotAgeWithoutReset
        self.now = now
        self.snapshotStore = snapshotStore
        let persistedSnapshot = snapshotStore.load(provider: .claude)
        lastSnapshot = persistedSnapshot
        lastSuccessfulFetchAt = persistedSnapshot?.fetchedAt
        nextAllowedRequestAt = snapshotStore.loadNextAllowedRequestAt(provider: .claude)
    }

    public func fetch() async throws -> UsageSnapshot {
        let (id, task) = inFlightLock.withLock { () -> (UUID, Task<UsageSnapshot, Error>) in
            if let inFlightFetch {
                return inFlightFetch
            }
            let id = UUID()
            let task = Task { try await self.fetchUncoalesced() }
            inFlightFetch = (id, task)
            return (id, task)
        }
        defer {
            inFlightLock.withLock {
                if inFlightFetch?.id == id {
                    inFlightFetch = nil
                }
            }
        }
        return try await task.value
    }

    private func fetchUncoalesced() async throws -> UsageSnapshot {
        let requestDate = now()
        let cachedSnapshot = snapshotLock.withLock { () -> UsageSnapshot? in
            guard let lastSnapshot else { return nil }
            if !isSnapshotUsable(lastSnapshot, at: requestDate) {
                self.lastSnapshot = nil
                lastSuccessfulFetchAt = nil
                return nil
            }
            if let nextAllowedRequestAt, requestDate < nextAllowedRequestAt {
                return lastSnapshot
            }
            if let lastSuccessfulFetchAt,
               requestDate.timeIntervalSince(lastSuccessfulFetchAt) < minimumFetchInterval {
                return lastSnapshot
            }
            return nil
        }
        if let cachedSnapshot {
            return cachedSnapshot
        }
        if snapshotLock.withLock({ nextAllowedRequestAt.map { requestDate < $0 } ?? false }) {
            throw ProviderClientError.claudeUnavailable("rate limited")
        }

        let credential = try credential()
        if let expiresAt = credential.expiresAt, expiresAt <= requestDate {
            throw ProviderClientError.claudeLoginExpired
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("aiusagebar/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let responseDate = now()
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.claudeUnavailable("invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderClientError.claudeLoginExpired
        }
        if http.statusCode == 429 {
            let retryAfter = retryDelay(
                headerValue: http.value(forHTTPHeaderField: "Retry-After"),
                relativeTo: responseDate
            )
            let backoffUntil = responseDate.addingTimeInterval(max(minimumFetchInterval, retryAfter))
            let fallback = snapshotLock.withLock { () -> UsageSnapshot? in
                nextAllowedRequestAt = backoffUntil
                guard let lastSnapshot, isSnapshotUsable(lastSnapshot, at: responseDate) else {
                    self.lastSnapshot = nil
                    lastSuccessfulFetchAt = nil
                    return nil
                }
                return lastSnapshot
            }
            snapshotStore.saveNextAllowedRequestAt(backoffUntil, provider: .claude)
            if let fallback {
                return fallback
            }
            throw ProviderClientError.claudeUnavailable("rate limited")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ProviderClientError.claudeUnavailable("HTTP \(http.statusCode)")
        }
        let parsed = try ClaudeUsageParser.parse(data: data)
        let snapshot = UsageSnapshot(
            provider: parsed.provider,
            weekly: parsed.weekly,
            fetchedAt: requestDate
        )
        snapshotLock.withLock {
            lastSnapshot = snapshot
            lastSuccessfulFetchAt = requestDate
            nextAllowedRequestAt = nil
        }
        snapshotStore.save(snapshot)
        snapshotStore.saveNextAllowedRequestAt(nil, provider: .claude)
        return snapshot
    }

    private func isSnapshotUsable(_ snapshot: UsageSnapshot, at date: Date) -> Bool {
        if let resetAt = snapshot.weekly.resetAt {
            return resetAt > date
        }
        return date.timeIntervalSince(snapshot.fetchedAt) < maximumSnapshotAgeWithoutReset
    }

    private func retryDelay(headerValue: String?, relativeTo date: Date) -> TimeInterval {
        guard let headerValue else { return 0 }
        if let seconds = TimeInterval(headerValue) {
            return max(0, seconds)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let retryDate = formatter.date(from: headerValue) else { return 0 }
        return max(0, retryDate.timeIntervalSince(date))
    }

    public func reloadCredentialOnNextFetch() {
        credentialLock.withLock {
            credentialCache = .unread
        }
    }

    private func credential() throws -> ClaudeCredential {
        try credentialLock.withLock {
            switch credentialCache {
            case .unread:
                break
            case let .loaded(credential):
                return credential
            case let .failed(error):
                throw error
            }

            do {
                let credential = try credentialReader.read()
                credentialCache = .loaded(credential)
                return credential
            } catch let error as ProviderClientError {
                credentialCache = .failed(error)
                throw error
            } catch {
                let error = ProviderClientError.claudeCredentialInvalid
                credentialCache = .failed(error)
                throw error
            }
        }
    }
}

private enum ClaudeCredentialCache {
    case unread
    case loaded(ClaudeCredential)
    case failed(ProviderClientError)
}

public struct ClaudeCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }
}

public protocol ClaudeCredentialReading: Sendable {
    func read() throws -> ClaudeCredential
}

public struct KeychainClaudeCredentialReader: ClaudeCredentialReading {
    public init() {}

    public func read() throws -> ClaudeCredential {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Code-credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderClientError.claudeCredentialMissing
        }

        let envelope = try JSONDecoder().decode(ClaudeCredentialEnvelope.self, from: data)
        let milliseconds = envelope.claudeAiOauth.expiresAt
        let expiresAt = milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        return ClaudeCredential(accessToken: envelope.claudeAiOauth.accessToken, expiresAt: expiresAt)
    }
}

private struct ClaudeCredentialEnvelope: Decodable {
    let claudeAiOauth: OAuth

    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Int64?
    }
}

private struct CodexCredentialEnvelope: Decodable {
    let tokens: Tokens

    struct Tokens: Decodable {
        let accessToken: String
        let accountID: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountID = "account_id"
        }
    }
}
