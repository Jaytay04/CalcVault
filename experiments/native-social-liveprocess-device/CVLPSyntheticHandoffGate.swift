import Foundation

/// UI-independent one-shot gate for the synthetic-only background handoff experiment.
public struct CVLPSyntheticHandoffGate {
    public enum Phase: Equatable {
        case idle
        case acquiringLease
        case holding
        case authenticating
        case awaitingActivation
        case readyToResume
        case resumed
        case revoked
    }

    public enum AuthenticationResult: Equatable {
        case readyToResume
        case awaitingActivation
        case failed
        case expired
        case backgrounded
        case stale
    }

    public static let maximumDuration: Duration = .seconds(120)

    public private(set) var generation: UInt64 = 0
    public private(set) var phase: Phase = .idle
    public private(set) var deadline: ContinuousClock.Instant?
    public private(set) var leaseAvailable = false

    private var startAttempted = false
    private var stopAttempted = false
    private var stopSubmitted = false
    private var authenticationAttempted = false
    private var authenticationAttempt: UInt64 = 0
    private var continuationAttempted = false

    public init() {}

    /// Starts the fixed deadline before the caller synchronously acquires its UIKit lease.
    public mutating func begin(
        now: ContinuousClock.Instant,
        foreground: Bool,
        protectedDataAvailable: Bool
    ) -> UInt64? {
        guard !startAttempted else { return nil }
        startAttempted = true
        guard foreground, protectedDataAvailable, generation < UInt64.max else {
            phase = .revoked
            return nil
        }
        generation += 1
        deadline = now.advanced(by: Self.maximumDuration)
        phase = .acquiringLease
        return generation
    }

    /// Commits the synchronously acquired lease, or terminally rejects the handoff.
    @discardableResult
    public mutating func leaseAcquired(
        token: UInt64,
        valid: Bool,
        now: ContinuousClock.Instant,
        protectedDataAvailable: Bool
    ) -> Bool {
        guard phase == .acquiringLease, token == generation else { return false }
        guard valid, protectedDataAvailable, hasTimeRemaining(now) else {
            revoke()
            return false
        }
        leaseAvailable = true
        phase = .holding
        return true
    }

    public func isLive(token: UInt64, now: ContinuousClock.Instant) -> Bool {
        token == generation && leaseAvailable && hasTimeRemaining(now) &&
            (phase == .holding || phase == .authenticating || phase == .awaitingActivation || phase == .readyToResume)
    }

    /// Reserves the sole SIGSTOP request. The caller must fail closed if submission is refused.
    public mutating func prepareStop(
        token: UInt64,
        now: ContinuousClock.Instant,
        foreground: Bool,
        protectedDataAvailable: Bool,
        guestAttached: Bool
    ) -> Bool {
        guard phase == .holding, !stopAttempted, isLive(token: token, now: now),
              foreground, protectedDataAvailable, guestAttached else { return false }
        stopAttempted = true
        return true
    }

    @discardableResult
    public mutating func stopRequestAccepted(token: UInt64, now: ContinuousClock.Instant) -> Bool {
        guard phase == .holding, token == generation, stopAttempted, !stopSubmitted,
              isLive(token: token, now: now) else { return false }
        stopSubmitted = true
        return true
    }

    /// Allows one fresh biometric-only authentication attempt for this hold.
    public mutating func beginAuthentication(
        token: UInt64,
        now: ContinuousClock.Instant,
        foreground: Bool,
        protectedDataAvailable: Bool
    ) -> UInt64? {
        guard phase == .holding, stopSubmitted, !authenticationAttempted,
              isLive(token: token, now: now), foreground, protectedDataAvailable,
              authenticationAttempt < UInt64.max else { return nil }
        authenticationAttempted = true
        authenticationAttempt += 1
        phase = .authenticating
        return authenticationAttempt
    }

    public mutating func completeAuthentication(
        token: UInt64,
        attempt: UInt64,
        succeeded: Bool,
        now: ContinuousClock.Instant,
        applicationActive: Bool,
        backgrounded: Bool,
        protectedDataAvailable: Bool
    ) -> AuthenticationResult {
        guard phase == .authenticating, token == generation, attempt == authenticationAttempt else {
            return .stale
        }
        guard isLive(token: token, now: now), protectedDataAvailable else {
            revoke()
            return .expired
        }
        guard succeeded else {
            revoke()
            return .failed
        }
        guard !backgrounded else {
            revoke()
            return .backgrounded
        }
        if applicationActive {
            phase = .readyToResume
            return .readyToResume
        }
        phase = .awaitingActivation
        return .awaitingActivation
    }

    /// Consumes a successful auth result only after the app reports active.
    @discardableResult
    public mutating func activateAfterAuthentication(
        token: UInt64,
        now: ContinuousClock.Instant,
        applicationActive: Bool,
        backgrounded: Bool,
        protectedDataAvailable: Bool
    ) -> Bool {
        guard phase == .awaitingActivation, token == generation, applicationActive,
              !backgrounded, protectedDataAvailable, isLive(token: token, now: now) else { return false }
        phase = .readyToResume
        return true
    }

    /// Reserves the sole SIGCONT request after all host-side resume checks pass.
    public mutating func prepareContinue(
        token: UInt64,
        now: ContinuousClock.Instant,
        foreground: Bool,
        protectedDataAvailable: Bool,
        guestAttached: Bool
    ) -> Bool {
        guard phase == .readyToResume, !continuationAttempted,
              isLive(token: token, now: now), foreground, protectedDataAvailable, guestAttached else { return false }
        continuationAttempted = true
        return true
    }

    @discardableResult
    public mutating func continueRequestAccepted(
        token: UInt64,
        now: ContinuousClock.Instant,
        foreground: Bool,
        protectedDataAvailable: Bool
    ) -> Bool {
        guard phase == .readyToResume, token == generation, continuationAttempted else { return false }
        guard isLive(token: token, now: now), foreground, protectedDataAvailable else {
            revoke(token: token)
            return false
        }
        phase = .resumed
        leaseAvailable = false
        return true
    }

    /// Revokes the token before callers cancel work and tear down the guest.
    public mutating func revoke(token: UInt64? = nil) {
        guard token == nil || token == generation else { return }
        guard phase != .revoked else { return }
        phase = .revoked
        leaseAvailable = false
        deadline = nil
        if generation < UInt64.max { generation += 1 }
    }

    private func hasTimeRemaining(_ now: ContinuousClock.Instant) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }
}
