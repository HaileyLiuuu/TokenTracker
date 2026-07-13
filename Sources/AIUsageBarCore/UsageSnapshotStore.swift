import Foundation

public protocol UsageSnapshotStoring: Sendable {
    func load(provider: ProviderID) -> UsageSnapshot?
    func save(_ snapshot: UsageSnapshot)
    func loadNextAllowedRequestAt(provider: ProviderID) -> Date?
    func saveNextAllowedRequestAt(_ date: Date?, provider: ProviderID)
}

public final class UserDefaultsUsageSnapshotStore: UsageSnapshotStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "lastUsageSnapshot"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func load(provider: ProviderID) -> UsageSnapshot? {
        lock.withLock {
            guard let data = defaults.data(forKey: key(for: provider)),
                  let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data),
                  snapshot.provider == provider else {
                return nil
            }
            return snapshot
        }
    }

    public func save(_ snapshot: UsageSnapshot) {
        lock.withLock {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: key(for: snapshot.provider))
        }
    }

    public func loadNextAllowedRequestAt(provider: ProviderID) -> Date? {
        lock.withLock {
            defaults.object(forKey: retryKey(for: provider)) as? Date
        }
    }

    public func saveNextAllowedRequestAt(_ date: Date?, provider: ProviderID) {
        lock.withLock {
            if let date {
                defaults.set(date, forKey: retryKey(for: provider))
            } else {
                defaults.removeObject(forKey: retryKey(for: provider))
            }
        }
    }

    private func key(for provider: ProviderID) -> String {
        "\(keyPrefix).\(provider.rawValue)"
    }

    private func retryKey(for provider: ProviderID) -> String {
        "\(keyPrefix).\(provider.rawValue).nextAllowedRequestAt"
    }
}
