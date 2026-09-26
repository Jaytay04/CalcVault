import Combine
import Foundation

public enum LifecycleState: Equatable {
    case calculatorLocked
    case authenticating(attemptID: UUID)
    case privateUnlocked(sessionID: UUID)
    case locking
}

/// Main-actor state machine for revocable private sessions.
///
/// Phase 0 does not provide a real authentication UI. The coordinator still
/// enforces the important lifecycle invariant: an attempt or session cannot be
/// accepted after an actual background transition.
@MainActor
public final class SessionLifecycleCoordinator: ObservableObject {
    @Published public private(set) var state: LifecycleState = .calculatorLocked
    @Published public private(set) var sessionGeneration: UInt64 = 0

    private var appIsActive = true
    private var activeAuthenticationAttempt: UUID?
    private var authenticationPromptIsActive = false

    public init() {}

    @discardableResult
    public func beginAuthentication() -> UUID {
        let attemptID = UUID()
        activeAuthenticationAttempt = attemptID
        authenticationPromptIsActive = true
        state = .authenticating(attemptID: attemptID)
        return attemptID
    }

    public func setAuthenticationPromptActive(_ active: Bool) {
        authenticationPromptIsActive = active
    }

    /// Completes only the currently active attempt while the app is in the
    /// foreground. Callers must still perform real passphrase/biometric work
    /// before invoking this method.
    @discardableResult
    public func completeAuthentication(attemptID: UUID) -> UUID? {
        guard appIsActive,
              case .authenticating(let expectedAttemptID) = state,
              expectedAttemptID == attemptID,
              activeAuthenticationAttempt == attemptID else {
            return nil
        }

        let sessionID = UUID()
        activeAuthenticationAttempt = nil
        authenticationPromptIsActive = false
        sessionGeneration &+= 1
        state = .privateUnlocked(sessionID: sessionID)
        return sessionID
    }

    public func lock() {
        activeAuthenticationAttempt = nil
        authenticationPromptIsActive = false
        sessionGeneration &+= 1
        state = .locking
        state = .calculatorLocked
    }

    public func applicationWillResignActive() {
        appIsActive = false

        // Face ID can make a scene inactive while its own prompt is visible.
        // Keep the attempt pending for that short transition, but the privacy
        // cover remains installed by PrivacyShieldController.
        if authenticationPromptIsActive {
            return
        }

        if case .privateUnlocked = state {
            lock()
        } else if case .authenticating = state {
            lock()
        }
    }

    public func applicationDidBecomeActive() {
        appIsActive = true

        // A pending prompt is allowed to finish only if LocalAuthentication
        // reports success while this scene is foregrounded. If no prompt is
        // active, a stale attempt is invalidated immediately.
        if !authenticationPromptIsActive, case .authenticating = state {
            lock()
        }
    }

    /// A genuine background transition always revokes an authentication
    /// attempt or private session, including while a biometric prompt is up.
    public func applicationDidEnterBackground() {
        appIsActive = false
        lock()
    }

    public func isValidSession(sessionID: UUID, generation: UInt64) -> Bool {
        guard case .privateUnlocked(let activeSessionID) = state else {
            return false
        }
        return activeSessionID == sessionID && generation == sessionGeneration && appIsActive
    }
}
