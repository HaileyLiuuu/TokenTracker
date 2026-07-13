import AIUsageBarCore
import Combine
import Foundation

struct ProviderState: Sendable {
    enum Failure: Sendable {
        case codexLoginExpired
        case loginExpired
        case codexUnavailable
        case claudeUnavailable
    }

    var snapshot: UsageSnapshot?
    var localTokens: Int?
    var failure: Failure?
    var isLoading = false

    static let loading = ProviderState(snapshot: nil, localTokens: nil, failure: nil, isLoading: true)
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var states: [ProviderID: ProviderState] = [
        .codex: .loading,
        .claude: .loading,
    ]
    @Published private(set) var isRefreshing = false
    @Published var primaryProvider: ProviderID {
        didSet { settings.primaryProvider = primaryProvider }
    }
    @Published var language: AppLanguage {
        didSet { settings.language = language }
    }

    private let settings: SettingsStore
    private var timer: Timer?
    private var lastRefreshCompletedAt: Date?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        primaryProvider = settings.primaryProvider
        language = settings.language
    }

    func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? .loading
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        for provider in ProviderID.allCases {
            var state = states[provider] ?? .loading
            state.isLoading = true
            states[provider] = state
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        Task {
            await withTaskGroup(of: (ProviderID, ProviderState).self) { group in
                group.addTask { (.codex, await Self.loadCodex(home: home)) }
                group.addTask { (.claude, await Self.loadClaude(home: home)) }
                for await (provider, state) in group {
                    states[provider] = state
                }
            }
            isRefreshing = false
            lastRefreshCompletedAt = Date()
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 30) {
        guard let lastRefreshCompletedAt else {
            refresh()
            return
        }
        if Date().timeIntervalSince(lastRefreshCompletedAt) >= maxAge {
            refresh()
        }
    }

    func startAutomaticRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private static func loadCodex(home: URL) async -> ProviderState {
        await Task.detached(priority: .utility) {
            do {
                let snapshot = try await CodexUsageClient().fetch()
                let cutoff = snapshot.weekly.startsAt ?? Date().addingTimeInterval(-7 * 86_400)
                let tokens = LocalTokenScanner.codexTokens(
                    in: [
                        home.appendingPathComponent(".codex/sessions", isDirectory: true),
                        home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
                    ],
                    since: cutoff
                )
                return ProviderState(snapshot: snapshot, localTokens: tokens, failure: nil)
            } catch ProviderClientError.codexCredentialMissing,
                    ProviderClientError.codexLoginExpired {
                let tokens = LocalTokenScanner.codexTokens(
                    in: [
                        home.appendingPathComponent(".codex/sessions", isDirectory: true),
                        home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
                    ],
                    since: Date().addingTimeInterval(-7 * 86_400)
                )
                return ProviderState(
                    snapshot: nil,
                    localTokens: tokens,
                    failure: .codexLoginExpired
                )
            } catch {
                let tokens = LocalTokenScanner.codexTokens(
                    in: [
                        home.appendingPathComponent(".codex/sessions", isDirectory: true),
                        home.appendingPathComponent(".codex/archived_sessions", isDirectory: true),
                    ],
                    since: Date().addingTimeInterval(-7 * 86_400)
                )
                return ProviderState(
                    snapshot: nil,
                    localTokens: tokens,
                    failure: .codexUnavailable
                )
            }
        }.value
    }

    private static func loadClaude(home: URL) async -> ProviderState {
        do {
            let snapshot = try await ClaudeUsageClient().fetch()
            let cutoff = snapshot.weekly.startsAt ?? Date().addingTimeInterval(-7 * 86_400)
            let tokens = await Task.detached(priority: .utility) {
                LocalTokenScanner.claudeTokens(
                    in: [home.appendingPathComponent(".claude/projects", isDirectory: true)],
                    since: cutoff
                )
            }.value
            return ProviderState(snapshot: snapshot, localTokens: tokens, failure: nil)
        } catch ProviderClientError.claudeCredentialMissing,
                ProviderClientError.claudeLoginExpired {
            let tokens = await recentClaudeTokens(home: home)
            return ProviderState(snapshot: nil, localTokens: tokens, failure: .loginExpired)
        } catch {
            let tokens = await recentClaudeTokens(home: home)
            return ProviderState(
                snapshot: nil,
                localTokens: tokens,
                failure: .claudeUnavailable
            )
        }
    }

    private static func recentClaudeTokens(home: URL) async -> Int {
        await Task.detached(priority: .utility) {
            LocalTokenScanner.claudeTokens(
                in: [home.appendingPathComponent(".claude/projects", isDirectory: true)],
                since: Date().addingTimeInterval(-7 * 86_400)
            )
        }.value
    }
}
