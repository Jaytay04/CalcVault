import Foundation

public struct AuthenticationRetryState: Codable, Equatable, Sendable {
    public var failureCount: Int
    public var retryNotBefore: Date?

    public init(failureCount: Int = 0, retryNotBefore: Date? = nil) {
        self.failureCount = failureCount
        self.retryNotBefore = retryNotBefore
    }
}

public protocol AuthenticationRetryPersisting: AnyObject {
    func load() -> AuthenticationRetryState
    func save(_ state: AuthenticationRetryState)
}

public final class UserDefaultsAuthenticationRetryStore: AuthenticationRetryPersisting {
    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.jaylintaylor.calcvault.authentication-retry-v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AuthenticationRetryState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(AuthenticationRetryState.self, from: data) else {
            return AuthenticationRetryState()
        }
        return state
    }

    public func save(_ state: AuthenticationRetryState) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Best-effort UI throttling. This does not claim to stop offline guesses
/// against a copied passphrase envelope.
public final class AuthenticationRateLimiter {
    private let store: AuthenticationRetryPersisting
    private let now: () -> Date

    public init(
        store: AuthenticationRetryPersisting = UserDefaultsAuthenticationRetryStore(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    public func retryAfter() -> TimeInterval? {
        let state = store.load()
        guard let retryNotBefore = state.retryNotBefore else { return nil }
        let remaining = retryNotBefore.timeIntervalSince(now())
        return remaining > 0 ? remaining : nil
    }

    @discardableResult
    public func recordFailure() -> TimeInterval {
        var state = store.load()
        state.failureCount = min(state.failureCount + 1, 32)
        let exponent = max(0, state.failureCount - 3)
        let delay = state.failureCount < 3 ? 0 : min(pow(2, Double(exponent)), 300)
        state.retryNotBefore = delay > 0 ? now().addingTimeInterval(delay) : nil
        store.save(state)
        return delay
    }

    public func recordSuccess() {
        store.save(AuthenticationRetryState())
    }
}
