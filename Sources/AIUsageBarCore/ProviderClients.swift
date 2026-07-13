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
    private let credentialLock = NSLock()
    private var credentialCache: ClaudeCredentialCache = .unread

    public init(
        credentialReader: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        session: URLSession = .shared
    ) {
        self.credentialReader = credentialReader
        self.session = session
    }

    public func fetch() async throws -> UsageSnapshot {
        let credential = try credential()
        if let expiresAt = credential.expiresAt, expiresAt <= Date() {
            throw ProviderClientError.claudeLoginExpired
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("aiusagebar/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.claudeUnavailable("invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderClientError.claudeLoginExpired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw ProviderClientError.claudeUnavailable("HTTP \(http.statusCode)")
        }
        return try ClaudeUsageParser.parse(data: data)
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
