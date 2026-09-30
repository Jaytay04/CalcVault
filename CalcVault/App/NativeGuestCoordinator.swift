import Combine
import Foundation
import UIKit

/// A runtime adapter must make its guest surface noninteractive synchronously
/// before stopping or releasing any underlying work in `revoke()`. Revocation
/// must be idempotent: locking and locked transitions both invalidate access.
@MainActor
public protocol NativeGuestRuntime: AnyObject {
    var viewController: UIViewController { get }
    var summary: String { get }
    func start(completion: @escaping @MainActor (Bool) -> Void)
    func revoke()
}

/// Coordinates one diagnostic-gated native guest attempt within the current
/// application launch. It never owns credentials or session authority.
@MainActor
public final class NativeGuestCoordinator: ObservableObject {
    public enum State: Equatable {
        case unavailable
        case idle
        case checking
        case presenting
        case running
        case blocked
        case ended
    }

    @Published public private(set) var state: State
    @Published public private(set) var showingGuest = false

    private struct SessionContext: Equatable {
        let sessionID: UUID
        let generation: UInt64
    }

    private struct CheckRequest: Equatable {
        let session: SessionContext
        let requestID: UUID
    }

    private let lifecycle: SessionLifecycleCoordinator
    private let checkLegacyCredentialAbsence: @Sendable (Bool) async throws -> Void
    private let runtimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?
    private var lifecycleObservation: AnyCancellable?
    private var activeRequest: CheckRequest?
    private var activeCheckTask: Task<Void, Never>?
    private var presentationRequest: CheckRequest?
    private var runtime: (any NativeGuestRuntime)?
    private var runtimeAttemptConsumed = false
    private var runtimeStartAttempted = false
    private var runtimeStartPending = false
    private var runtimeRevoked = false

    public init(
        lifecycle: SessionLifecycleCoordinator,
        check: @escaping @Sendable (Bool) async throws -> Void,
        runtimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?
    ) {
        self.lifecycle = lifecycle
        self.checkLegacyCredentialAbsence = check
        self.runtimeFactory = runtimeFactory
        self.state = runtimeFactory == nil ? .unavailable : .idle

        lifecycleObservation = lifecycle.$state
            .dropFirst()
            .sink { [weak self] _ in
                // Published emits during willSet. Every lifecycle transition
                // revokes the current request without consulting the old value.
                MainActor.assumeIsolated {
                    self?.invalidateForLifecycleTransition()
                }
            }
    }

    /// Exposes a controller only while the presentation is tied to the active
    /// private session and has not been revoked.
    public var viewController: UIViewController? {
        guard showingGuest,
              !runtimeRevoked,
              (state == .presenting || state == .running),
              let presentationRequest,
              isValid(presentationRequest.session) else {
            return nil
        }
        return runtime?.viewController
    }

    /// Runtime summaries are surfaced only for an authorized live presentation.
    /// After reauthentication, a retained runtime summary remains available as a
    /// diagnostic report without restoring access to its revoked controller.
    /// Locked/authenticating states always use fixed, non-error details.
    public var summary: String {
        if validSessionContext() != nil, let runtime {
            return runtime.summary
        }

        switch state {
        case .unavailable:
            return "Native guest runtime is unavailable."
        case .idle:
            return "Native guest is ready for a session check."
        case .checking:
            return "Checking the current session."
        case .presenting:
            return "Native guest is ready."
        case .running:
            return "Native guest is running."
        case .blocked:
            return "Native guest could not be started."
        case .ended:
            return "Native guest session ended."
        }
    }

    /// Starts a fresh check only for an active private session. A runtime can
    /// be attempted once per coordinator instance, including across lock/unlock.
    @discardableResult
    public func start(biometricEnabled: Bool) -> Task<Void, Never>? {
        guard runtimeFactory != nil, !runtimeAttemptConsumed else {
            if runtimeFactory == nil {
                state = .unavailable
            }
            return nil
        }

        guard activeRequest == nil else { return nil }
        guard let session = validSessionContext() else {
            state = .blocked
            return nil
        }

        let request = CheckRequest(session: session, requestID: UUID())
        let checker = checkLegacyCredentialAbsence
        activeRequest = request
        state = .checking

        let task = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                guard !Task.isCancelled, self?.canRunCheck(request) == true else {
                    self?.cancelCheck(request)
                    return
                }

                do {
                    try await checker(biometricEnabled)
                    guard !Task.isCancelled else {
                        self?.cancelCheck(request)
                        return
                    }
                    self?.finishCheck(request, succeeded: true)
                } catch {
                    if Task.isCancelled {
                        self?.cancelCheck(request)
                    } else {
                        self?.finishCheck(request, succeeded: false)
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelCheck(request)
                }
            }
        }
        activeCheckTask = task
        return task
    }

    /// Call after the full-screen host has attached the authorized controller.
    /// Repeated calls never start the runtime twice.
    public func surfaceReady() {
        guard state == .presenting,
              showingGuest,
              !runtimeRevoked else { return }
        guard !runtimeStartAttempted else { return }
        guard let runtime,
              let presentationRequest,
              isValid(presentationRequest.session) else {
            endRuntimePresentation()
            return
        }

        runtimeStartAttempted = true
        runtimeStartPending = true
        runtime.start { [weak self] started in
            self?.runtimeDidStart(presentationRequest, started: started)
        }
    }

    private func canRunCheck(_ request: CheckRequest) -> Bool {
        activeRequest == request
            && !runtimeAttemptConsumed
            && runtimeFactory != nil
            && isValid(request.session)
    }

    private func finishCheck(_ request: CheckRequest, succeeded: Bool) {
        guard activeRequest == request else { return }
        activeRequest = nil
        activeCheckTask = nil

        guard isValid(request.session) else {
            state = .idle
            return
        }
        guard succeeded else {
            state = .blocked
            return
        }

        // Consume the attempt before entering the injected factory, including
        // the throwing-factory path. A lock can never make it reusable.
        runtimeAttemptConsumed = true
        guard let runtimeFactory else {
            state = .unavailable
            return
        }

        do {
            let createdRuntime = try runtimeFactory()
            runtime = createdRuntime
            guard isValid(request.session) else {
                showingGuest = false
                presentationRequest = nil
                runtimeStartPending = false
                createdRuntime.revoke()
                runtimeRevoked = true
                state = .ended
                return
            }

            runtimeRevoked = false
            runtimeStartAttempted = false
            runtimeStartPending = false
            presentationRequest = request
            showingGuest = true
            state = .presenting
        } catch {
            state = isValid(request.session) ? .blocked : .ended
        }
    }

    private func cancelCheck(_ request: CheckRequest) {
        guard activeRequest == request else { return }
        activeRequest = nil
        activeCheckTask = nil
        state = runtimeFactory == nil ? .unavailable : .idle
    }

    private func runtimeDidStart(_ request: CheckRequest, started: Bool) {
        guard runtimeStartPending,
              presentationRequest == request,
              showingGuest,
              state == .presenting,
              !runtimeRevoked,
              isValid(request.session) else {
            endRuntimePresentation()
            return
        }

        runtimeStartPending = false
        if started {
            state = .running
        } else {
            showingGuest = false
            runtime?.revoke()
            runtimeRevoked = true
            state = .blocked
        }
    }

    private func endRuntimePresentation() {
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtime?.revoke()
        runtimeRevoked = runtime != nil
        if runtimeAttemptConsumed {
            state = .ended
        }
    }

    private func invalidateForLifecycleTransition() {
        // Hide access before invoking the adapter's revoke implementation.
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        if let runtime {
            runtime.revoke()
            runtimeRevoked = true
        }

        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        state = runtimeAttemptConsumed ? .ended : (runtimeFactory == nil ? .unavailable : .idle)
    }

    private func validSessionContext() -> SessionContext? {
        guard case .privateUnlocked(let sessionID) = lifecycle.state else {
            return nil
        }

        let session = SessionContext(
            sessionID: sessionID,
            generation: lifecycle.sessionGeneration
        )
        return isValid(session) ? session : nil
    }

    private func isValid(_ session: SessionContext) -> Bool {
        lifecycle.isValidSession(
            sessionID: session.sessionID,
            generation: session.generation
        )
    }
}
