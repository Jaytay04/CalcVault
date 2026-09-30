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
    private struct PrivateAuthenticationPrompt {
        let token: UUID
        let sessionID: UUID
        let generation: UInt64
    }
    private var privateAuthenticationPrompt: PrivateAuthenticationPrompt?
    private var privatePromptWaiter: CheckedContinuation<Bool, Never>?
    private var privatePromptDeadline: Task<Void, Never>?
    private var privatePromptTimeoutNanoseconds: UInt64 = 45_000_000_000

    public init() {}

    internal init(privatePromptTimeoutNanoseconds: UInt64) {
        self.privatePromptTimeoutNanoseconds = privatePromptTimeoutNanoseconds
    }

    @discardableResult
    public func beginAuthentication() -> UUID {
        clearPrivateAuthenticationPrompt(result: false)
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
        clearPrivateAuthenticationPrompt(result: false)
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
        if authenticationPromptIsActive || privateAuthenticationPrompt != nil {
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

        if privatePromptWaiter != nil, let prompt = privateAuthenticationPrompt {
            let current = matchesPrivatePromptSession(prompt)
            clearPrivateAuthenticationPrompt(result: current)
        }

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
            && privateAuthenticationPrompt == nil
    }

    /// Narrow, bounded exception for a user-requested biometric credential
    /// check in an already authenticated session. Session validation rejects
    /// guest work while the prompt is pending; background and explicit lock revoke it.
    public func beginPrivateAuthenticationPrompt(sessionID: UUID, generation: UInt64) -> UUID? {
        guard !authenticationPromptIsActive,
              isValidSession(sessionID: sessionID, generation: generation) else { return nil }
        let token = UUID()
        privateAuthenticationPrompt = PrivateAuthenticationPrompt(
            token: token, sessionID: sessionID, generation: generation
        )
        let timeout = privatePromptTimeoutNanoseconds
        privatePromptDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard self?.privateAuthenticationPrompt?.token == token else { return }
            self?.lock()
        }
        return token
    }

    /// Authentication can complete before UIKit reports foreground activation.
    /// Keep the privacy exception scoped until that event; never return success
    /// while inactive. Lock/background/deadline resumes this wait with false.
    public func completePrivateAuthenticationPrompt(_ token: UUID) async -> Bool {
        guard let prompt = privateAuthenticationPrompt, prompt.token == token,
              matchesPrivatePromptSession(prompt), privatePromptWaiter == nil else { return false }
        if appIsActive {
            clearPrivateAuthenticationPrompt(result: true)
            return true
        }
        return await withCheckedContinuation { privatePromptWaiter = $0 }
    }

    public func cancelPrivateAuthenticationPrompt(_ token: UUID) {
        guard privateAuthenticationPrompt?.token == token else { return }
        clearPrivateAuthenticationPrompt(result: false)
        // A cancelled prompt is no longer a reason to retain an inactive session.
        if !appIsActive { lock() }
    }

    private func matchesPrivatePromptSession(_ prompt: PrivateAuthenticationPrompt) -> Bool {
        guard case .privateUnlocked(let sessionID) = state else { return false }
        return sessionID == prompt.sessionID && sessionGeneration == prompt.generation
    }

    private func clearPrivateAuthenticationPrompt(result: Bool) {
        privateAuthenticationPrompt = nil
        privatePromptDeadline?.cancel()
        privatePromptDeadline = nil
        let waiter = privatePromptWaiter
        privatePromptWaiter = nil
        waiter?.resume(returning: result)
    }
}
