import Foundation
import Security

public enum ProviderClientError: LocalizedError {
    case codexNotInstalled
    case codexTimedOut(String?)
    case codexUnavailable(String)
    case claudeCredentialMissing
    case claudeLoginExpired
    case claudeUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            "Codex CLI is not installed."
        case let .codexTimedOut(diagnostics):
            if let diagnostics, !diagnostics.isEmpty {
                "Codex usage request timed out: \(diagnostics)"
            } else {
                "Codex usage request timed out."
            }
        case let .codexUnavailable(message):
            "Codex usage is unavailable: \(message)"
        case .claudeCredentialMissing:
            "Claude Code is not signed in."
        case .claudeLoginExpired:
            "Claude Code sign-in has expired."
        case let .claudeUnavailable(message):
            "Claude Code usage is unavailable: \(message)"
        }
    }
}

public final class CodexUsageClient {
    private let executableURL: URL

    public init(executableURL: URL? = nil) throws {
        if let executableURL {
            self.executableURL = executableURL
        } else if let discovered = Self.findCodexExecutable() {
            self.executableURL = discovered
        } else {
            throw ProviderClientError.codexNotInstalled
        }
    }

    public func fetch(timeout: TimeInterval = 20) throws -> UsageSnapshot {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let response = ResponseBox()
        let diagnostics = DiagnosticBuffer()
        let semaphore = DispatchSemaphore(value: 0)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            response.append(data) { line in
                do {
                    if let snapshot = try CodexRateLimitParser.parse(line: line) {
                        response.finish(.success(snapshot))
                        semaphore.signal()
                    }
                } catch {
                    response.finish(.failure(error))
                    semaphore.signal()
                }
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { diagnostics.append(data) }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw ProviderClientError.codexUnavailable(error.localizedDescription)
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"aiusagebar","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
        ].joined(separator: "\n") + "\n"
        inputPipe.fileHandleForWriting.write(Data(requests.utf8))

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard waitResult == .success else {
            throw ProviderClientError.codexTimedOut(diagnostics.text)
        }
        return try response.result?.get() ?? {
            throw ProviderClientError.codexUnavailable("empty response")
        }()
    }

    private static func findCodexExecutable() -> URL? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CODEX_BIN"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/codex",
        ])
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
}

public final class ClaudeUsageClient {
    private let credentialReader: ClaudeCredentialReading
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init(
        credentialReader: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        session: URLSession = .shared
    ) {
        self.credentialReader = credentialReader
        self.session = session
    }

    public func fetch() async throws -> UsageSnapshot {
        let credential = try credentialReader.read()
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

private final class ResponseBox {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var result: Result<UsageSnapshot, Error>?

    func append(_ data: Data, onLine: (String) -> Void) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func finish(_ newResult: Result<UsageSnapshot, Error>) {
        lock.lock()
        if result == nil { result = newResult }
        lock.unlock()
    }
}

private final class DiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes = 8_192
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        let remaining = max(maximumBytes - buffer.count, 0)
        if remaining > 0 { buffer.append(data.prefix(remaining)) }
        lock.unlock()
    }

    var text: String? {
        lock.lock()
        let value = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        return value?.isEmpty == false ? value : nil
    }
}
