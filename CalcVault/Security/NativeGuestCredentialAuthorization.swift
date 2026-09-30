import Foundation
import LocalAuthentication

@MainActor
public protocol NativeGuestCredentialAuthorization: AnyObject {
    func authenticate() async throws
    func check(biometricEnabled: Bool) async throws
    func invalidate()
}

public enum NativeGuestCredentialAuthorizationError: Error, Equatable {
    case authenticationRequired
    case attemptAlreadyUsed
    case invalidated
}

/// Performs one biometric authentication and one metadata-only credential
/// boundary retry for a native guest attempt. The coordinator owns the attempt
/// lifetime and must invalidate this object when that attempt ends.
@MainActor
public final class NativeGuestBiometricAuthorization: NativeGuestCredentialAuthorization {
    private enum State {
        case ready
        case authenticating
        case authenticated
        case checking
        case checked
        case invalidated
    }

    private static let localizedReason = "Verify protected credentials before opening the isolated guest"

    private let context: LAContext
    private let storage: HostOnlyKeychainStorage
    private let biometricEvaluator: @MainActor (LAContext, String) async throws -> Void
    private var state: State = .ready
    private var checkTask: Task<Void, Error>?

    public convenience init() {
        self.init(context: LAContext(), storage: HostOnlyKeychainStorage()) { context, reason in
            guard try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) else {
                throw NativeGuestCredentialAuthorizationError.authenticationRequired
            }
        }
    }

    init(
        context: LAContext,
        storage: HostOnlyKeychainStorage,
        biometricEvaluator: @escaping @MainActor (LAContext, String) async throws -> Void
    ) {
        self.context = context
        self.storage = storage
        self.biometricEvaluator = biometricEvaluator
        context.localizedFallbackTitle = ""
    }

    public func authenticate() async throws {
        switch state {
        case .ready:
            state = .authenticating
        case .invalidated:
            throw NativeGuestCredentialAuthorizationError.invalidated
        default:
            throw NativeGuestCredentialAuthorizationError.attemptAlreadyUsed
        }

        do {
            try Task.checkCancellation()
            let transfer = NativeGuestAuthorizationContextTransfer(context: context)
            try await withTaskCancellationHandler {
                try await biometricEvaluator(context, Self.localizedReason)
            } onCancel: {
                transfer.context.invalidate()
            }
            try Task.checkCancellation()
            guard case .authenticating = state else {
                throw NativeGuestCredentialAuthorizationError.invalidated
            }
            state = .authenticated
        } catch {
            invalidate()
            throw error
        }
    }

    public func check(biometricEnabled: Bool) async throws {
        switch state {
        case .authenticated:
            state = .checking
        case .invalidated:
            throw NativeGuestCredentialAuthorizationError.invalidated
        case .ready, .authenticating:
            throw NativeGuestCredentialAuthorizationError.authenticationRequired
        default:
            throw NativeGuestCredentialAuthorizationError.attemptAlreadyUsed
        }

        do {
            try Task.checkCancellation()
            let transfer = NativeGuestAuthorizationContextTransfer(context: context)
            let storage = self.storage
            let work = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try NativeGuestCredentialInventory.checkForLaunch(
                    biometricEnabled: biometricEnabled,
                    storage: storage,
                    context: transfer.context
                )
                try Task.checkCancellation()
            }
            checkTask = work
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
                transfer.context.invalidate()
            }
            guard case .checking = state else {
                throw NativeGuestCredentialAuthorizationError.invalidated
            }
            checkTask = nil
            state = .checked
        } catch {
            checkTask = nil
            invalidate()
            throw error
        }
    }

    public func invalidate() {
        guard case .invalidated = state else {
            state = .invalidated
            checkTask?.cancel()
            context.invalidate()
            return
        }
    }
}

/// LAContext is a framework reference type used by the synchronous Security
/// adapter inside a detached task. Inventory queries are sequential; explicit
/// invalidation may race them intentionally to revoke the attempt promptly.
private struct NativeGuestAuthorizationContextTransfer: @unchecked Sendable {
    let context: LAContext
}
