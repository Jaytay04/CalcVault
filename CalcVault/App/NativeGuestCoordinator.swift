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

/// A runtime that can briefly suspend and later resume a verified guest while
/// the host performs a bounded, user-requested verification flow. A successful
/// suspension callback must confirm that guest content and active media are
/// actually quiescent; accepting a suspension request alone is insufficient.
@MainActor
public protocol NativeGuestVerificationRuntime: NativeGuestRuntime {
    func suspendForVerification(completion: @escaping @MainActor (Bool) -> Void)
    func resumeAfterVerification(completion: @escaping @MainActor (Bool) -> Void)
}

/// A host-owned lease that bounds how long a suspended runtime may be retained.
@MainActor
public protocol NativeGuestHandoffLease: AnyObject {
    var isValid: Bool { get }
    func end()
}

/// Allowlisted preparation failures only. Never carry an underlying error,
/// filesystem path, entitlement value or credential into the UI report.
public enum NativeGuestPreparationFailure: String, Error, Sendable {
    case signingExport = "signing-export-absence"
    case immutableContract = "immutable-framework-contract"
    case hostSupport = "host-support-directory"
    case hostFixtureDirectory = "host-fixture-directory"
    case hostSentinelCreate = "host-sentinel-create"
    case hostSentinelReadback = "host-sentinel-readback"
    case hostDocuments = "host-documents-directory"
    case guestDirectoryType = "guest-directory-type"
    case guestDirectoryCreate = "guest-directory-create"
    case appIDControl = "synthetic-app-id-control"
    case hostOnlyControl = "synthetic-host-only-control"
    case bothControls = "synthetic-both-controls"
    case unclassified
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
        case holding
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
    private let authorizationFactory: (@MainActor () -> any NativeGuestCredentialAuthorization)?
    private let handoffLeaseFactory: (@MainActor (@escaping @MainActor () -> Void) -> (any NativeGuestHandoffLease)?)?
    private let handoffDuration: Duration
    private struct ActiveAuthorization {
        let request: CheckRequest
        let promptToken: UUID
        let authorization: any NativeGuestCredentialAuthorization
    }
    private enum AuthenticationFailure: Error { case unavailable }
    private var activeAuthorization: ActiveAuthorization?
    private var lifecycleObservation: AnyCancellable?
    private var activeRequest: CheckRequest?
    private var activeCheckTask: Task<Void, Never>?
    private var presentationRequest: CheckRequest?
    private var runtime: (any NativeGuestRuntime)?
    private var runtimeAttemptConsumed = false
    private var runtimeStartAttempted = false
    private var runtimeStartPending = false
    private var runtimeRevoked = false
    private var launchFailure: String?
    private struct VerificationHandoff {
        let token: UUID
        let originatingSession: SessionContext
        let runtime: any NativeGuestVerificationRuntime
        let lease: any NativeGuestHandoffLease
        let deadline: ContinuousClock.Instant
        var suspensionAcknowledged = false
        var resumePending = false
    }
    private var verificationHandoff: VerificationHandoff?
    private var handoffDeadlineTask: Task<Void, Never>?
    private var verificationOperationID: UUID?

    public init(
        lifecycle: SessionLifecycleCoordinator,
        check: @escaping @Sendable (Bool) async throws -> Void,
        runtimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?,
        authorizationFactory: (@MainActor () -> any NativeGuestCredentialAuthorization)? = nil,
        leaseFactory: (@MainActor (@escaping @MainActor () -> Void) -> (any NativeGuestHandoffLease)?)? = nil
    ) {
        self.lifecycle = lifecycle
        self.checkLegacyCredentialAbsence = check
        self.runtimeFactory = runtimeFactory
        self.authorizationFactory = authorizationFactory
        self.handoffLeaseFactory = leaseFactory
        self.handoffDuration = .seconds(120)
        self.state = runtimeFactory == nil ? .unavailable : .idle

        observeLifecycle()
    }

    internal init(
        lifecycle: SessionLifecycleCoordinator,
        check: @escaping @Sendable (Bool) async throws -> Void,
        runtimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?,
        authorizationFactory: (@MainActor () -> any NativeGuestCredentialAuthorization)? = nil,
        leaseFactory: (@MainActor (@escaping @MainActor () -> Void) -> (any NativeGuestHandoffLease)?)? = nil,
        handoffDuration: Duration
    ) {
        self.lifecycle = lifecycle
        self.checkLegacyCredentialAbsence = check
        self.runtimeFactory = runtimeFactory
        self.authorizationFactory = authorizationFactory
        self.handoffLeaseFactory = leaseFactory
        self.handoffDuration = min(handoffDuration, .seconds(120))
        self.state = runtimeFactory == nil ? .unavailable : .idle

        observeLifecycle()
    }

    private func observeLifecycle() {
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
        return runtime?.viewController ?? verificationHandoff?.runtime.viewController
    }

    /// Presentation hint only. `start` independently enforces every launch gate.
    /// A failed credential check can be retried; a consumed runtime cannot.
    public var canRequestLaunch: Bool {
        runtimeFactory != nil && !runtimeAttemptConsumed && activeRequest == nil
            && (state == .idle || state == .blocked) && validSessionContext() != nil
    }

    /// True only while an active guest, verification capability and a lease
    /// factory are available to begin the bounded handoff.
    public var canBeginVerificationHandoff: Bool {
        state == .running
            && showingGuest
            && !runtimeRevoked
            && presentationRequest.map { isValid($0.session) } == true
            && runtime is any NativeGuestVerificationRuntime
            && handoffLeaseFactory != nil
    }

    /// Internal mount point retained while the guest is hidden during a hold.
    /// It never grants interaction or public presentation authority.
    internal var mountedViewController: UIViewController? {
        guard !runtimeRevoked,
              (showingGuest && presentationRequest.map { isValid($0.session) } == true)
                || verificationHandoff != nil else { return nil }
        return runtime?.viewController ?? verificationHandoff?.runtime.viewController
    }

    /// Resume is offered only after suspension acknowledgement and while the
    /// bounded lease, deadline, and a fresh private session all remain valid.
    public var canResumeVerification: Bool {
        guard let handoff = verificationHandoff,
              handoff.suspensionAcknowledged,
              !handoff.resumePending,
              activeRequest == nil,
              state == .holding || state == .blocked,
              handoff.lease.isValid,
              ContinuousClock().now < handoff.deadline,
              let session = validSessionContext(),
              session != handoff.originatingSession else { return false }
        return true
    }

    /// Runtime summaries are surfaced only for an authorized live presentation.
    /// After reauthentication, a retained runtime summary remains available as a
    /// diagnostic report without restoring access to its revoked controller.
    /// Locked/authenticating states always use fixed, non-error details.
    public var summary: String {
        if validSessionContext() != nil {
            if let launchFailure {
                let diagnostic = "Native launch diagnostic v1\n\(launchFailure)"
                return runtime.map { diagnostic + "\n\n" + $0.summary } ?? diagnostic
            }
            if let runtime { return runtime.summary }
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
        case .holding:
            return verificationHandoff?.suspensionAcknowledged == true
                ? "Native guest is held for verification."
                : "Native guest verification handoff is pending."
        case .blocked:
            return "Native guest could not be started."
        case .ended:
            return "Native guest session ended."
        }
    }

    /// Starts a fresh check only for an active private session. Runtime creation
    /// remains one-shot; a bounded held runtime can only enter its resume path.
    @discardableResult
    public func start(biometricEnabled: Bool) -> Task<Void, Never>? {
        guard runtimeFactory != nil else {
            state = .unavailable
            return nil
        }

        guard activeRequest == nil else { return nil }
        guard let session = validSessionContext() else {
            state = .blocked
            return nil
        }

        if let handoff = verificationHandoff {
            guard !handoff.resumePending,
                  state == .holding || state == .blocked else { return nil }
            guard handoff.suspensionAcknowledged else { return nil }
            guard handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline else {
                endVerificationHandoff(reason: "lease-expired")
                return nil
            }
            guard session != handoff.originatingSession else { return nil }
        } else if runtimeAttemptConsumed {
            return nil
        }

        let request = CheckRequest(session: session, requestID: UUID())
        launchFailure = nil
        activeRequest = request
        state = .checking

        let task = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                guard !Task.isCancelled, self?.canRunCheck(request) == true else {
                    self?.cancelCheck(request)
                    return
                }

                do {
                    guard let self else { return }
                    try await self.checkCredentials(request, biometricEnabled: biometricEnabled)
                    guard !Task.isCancelled else {
                        self.cancelCheck(request)
                        return
                    }
                    self.finishCheck(request, failure: nil)
                } catch {
                    if Task.isCancelled {
                        self?.cancelCheck(request)
                    } else {
                        let code = (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode
                            ?? "unclassified"
                        let preference = biometricEnabled ? "enabled" : "disabled"
                        let failure = error is AuthenticationFailure
                            ? "stage=credential-authentication; reason=cancelled-or-unavailable"
                            : "stage=credential-boundary; " + code + "; biometric=" + preference
                        self?.finishCheck(request, failure: failure)
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

    /// Hides the current presentation before asking the runtime to suspend.
    /// The runtime is retained only by a unique, expiring handoff token.
    @discardableResult
    public func beginVerificationHandoff() -> Bool {
        guard state == .running, showingGuest, !runtimeRevoked,
              presentationRequest.map({ isValid($0.session) }) == true else { return false }
        guard let runtime = runtime as? any NativeGuestVerificationRuntime,
              let leaseFactory = handoffLeaseFactory else {
            launchFailure = "stage=verification-handoff; reason=unsupported"
            return false
        }

        let token = UUID()
        var leaseInvalidatedDuringCreation = false
        guard let lease = leaseFactory({ [weak self] in
            leaseInvalidatedDuringCreation = true
            self?.handoffLeaseDidEnd(token)
        }) else {
            launchFailure = "stage=verification-handoff; reason=lease-unavailable"
            return false
        }
        guard lease.isValid, !leaseInvalidatedDuringCreation else {
            lease.end()
            launchFailure = "stage=verification-handoff; reason=lease-unavailable"
            return false
        }

        guard let originatingSession = presentationRequest?.session else {
            lease.end()
            return false
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: handoffDuration)
        let handoff = VerificationHandoff(
            token: token,
            originatingSession: originatingSession,
            runtime: runtime,
            lease: lease,
            deadline: deadline
        )

        // Remove presentation authority before the adapter can begin work.
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtimeStartAttempted = true
        self.runtime = nil
        verificationHandoff = handoff
        runtimeRevoked = false
        launchFailure = nil
        state = .holding
        handoffDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard self?.verificationHandoff?.token == token else { return }
            self?.endVerificationHandoff(reason: "lease-expired")
        }

        runtime.suspendForVerification { [weak self] suspended in
            self?.verificationSuspended(token: token, suspended: suspended)
        }
        return true
    }

    /// Hard termination for an explicit lock or protected lifecycle boundary.
    /// This is idempotent and never extends the active handoff deadline.
    public func endVerificationHandoff() {
        if verificationHandoff != nil {
            endVerificationHandoff(reason: "ended")
            return
        }

        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        if let request = activeAuthorization?.request { endAuthorization(request) }
        endRuntimePresentation()
    }

    /// Call after the full-screen host has attached the authorized controller.
    /// Repeated calls never start the runtime twice.
    public func surfaceReady() {
        guard state == .presenting,
              showingGuest,
              !runtimeRevoked else { return }

        if let handoff = verificationHandoff {
            guard handoff.suspensionAcknowledged,
                  !handoff.resumePending,
                  handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline,
                  let presentationRequest = self.presentationRequest,
                  presentationRequest.session != handoff.originatingSession,
                  isValid(presentationRequest.session) else {
                if let handoff = verificationHandoff,
                   (!handoff.lease.isValid || ContinuousClock().now >= handoff.deadline) {
                    endVerificationHandoff(reason: "lease-expired")
                }
                return
            }

            let operationID = UUID()
            verificationOperationID = operationID
            self.verificationHandoff?.resumePending = true
            handoff.runtime.resumeAfterVerification { [weak self] resumed in
                self?.verificationResumed(
                    token: handoff.token,
                    operationID: operationID,
                    request: presentationRequest,
                    resumed: resumed
                )
            }
            return
        }

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
            && (!runtimeAttemptConsumed || verificationHandoff != nil)
            && runtimeFactory != nil
            && isValid(request.session)
    }

    private func checkCredentials(_ request: CheckRequest, biometricEnabled: Bool) async throws {
        do {
            try await checkLegacyCredentialAbsence(biometricEnabled)
            return
        } catch {
            guard !Task.isCancelled, canRunCheck(request),
                  let failure = error as? NativeGuestCredentialBoundaryFailure,
                  failure.requiresBiometricAuthentication(biometricEnabled: biometricEnabled),
                  authorizationFactory != nil else { throw error }
        }

        guard let authorizationFactory,
              let token = lifecycle.beginPrivateAuthenticationPrompt(
            sessionID: request.session.sessionID, generation: request.session.generation
        ) else { throw CancellationError() }
        let authorization = authorizationFactory()
        activeAuthorization = ActiveAuthorization(
            request: request, promptToken: token, authorization: authorization
        )
        defer { endAuthorization(request) }
        do {
            try await authorization.authenticate()
        } catch {
            throw AuthenticationFailure.unavailable
        }
        try Task.checkCancellation()
        guard activeRequest == request,
              await lifecycle.completePrivateAuthenticationPrompt(token),
              canRunCheck(request) else { throw CancellationError() }
        // A successful biometric Boolean is not the boundary verdict. Repeat
        // the entire inventory check with that context, still forbidding UI.
        try await authorization.check(biometricEnabled: biometricEnabled)
        try Task.checkCancellation()
    }

    private func endAuthorization(_ request: CheckRequest) {
        guard let active = activeAuthorization, active.request == request else { return }
        activeAuthorization = nil
        active.authorization.invalidate()
        lifecycle.cancelPrivateAuthenticationPrompt(active.promptToken)
    }

    private func finishCheck(_ request: CheckRequest, failure: String?) {
        guard activeRequest == request else { return }
        activeRequest = nil
        activeCheckTask = nil

        guard isValid(request.session) else {
            state = verificationHandoff == nil ? .idle : .holding
            return
        }
        if let failure {
            launchFailure = failure
            state = .blocked
            return
        }

        if let handoff = verificationHandoff {
            guard handoff.suspensionAcknowledged,
                  handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline,
                  request.session != handoff.originatingSession else {
                endVerificationHandoff(reason: "lease-expired")
                return
            }

            runtimeRevoked = false
            runtimeStartPending = false
            presentationRequest = request
            showingGuest = true
            state = .presenting
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
            if isValid(request.session) {
                let code = (error as? NativeGuestPreparationFailure)?.rawValue ?? "unclassified"
                launchFailure = "stage=runtime-preparation; reason=" + code
                state = .blocked
            } else {
                state = .ended
            }
        }
    }

    private func cancelCheck(_ request: CheckRequest) {
        guard activeRequest == request else { return }
        endAuthorization(request)
        activeRequest = nil
        activeCheckTask = nil
        state = verificationHandoff != nil
            ? .holding
            : (runtimeFactory == nil ? .unavailable : .idle)
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
            launchFailure = "stage=runtime-start; reason=request-rejected"
            showingGuest = false
            runtime?.revoke()
            runtimeRevoked = true
            state = .blocked
        }
    }

    private func verificationSuspended(token: UUID, suspended: Bool) {
        guard verificationHandoff?.token == token else { return }
        guard let handoff = verificationHandoff else { return }
        guard handoff.lease.isValid, ContinuousClock().now < handoff.deadline else {
            endVerificationHandoff(reason: "lease-expired")
            return
        }
        guard !handoff.suspensionAcknowledged else { return }
        guard suspended else {
            endVerificationHandoff(reason: "suspension-rejected")
            return
        }

        verificationHandoff?.suspensionAcknowledged = true
        state = .holding
    }

    private func verificationResumed(
        token: UUID,
        operationID: UUID,
        request: CheckRequest,
        resumed: Bool
    ) {
        guard let handoff = verificationHandoff, handoff.token == token else { return }
        guard verificationOperationID == operationID,
              handoff.resumePending,
              presentationRequest == request,
              showingGuest,
              state == .presenting,
              request.session != handoff.originatingSession,
              isValid(request.session) else {
            // If a resume finishes after the host session changed, the runtime's
            // actual state is uncertain. Revoke the bounded hold fail-closed.
            endVerificationHandoff(reason: "stale-resume")
            return
        }
        guard handoff.lease.isValid, ContinuousClock().now < handoff.deadline else {
            endVerificationHandoff(reason: "lease-expired")
            return
        }
        guard resumed else {
            endVerificationHandoff(reason: "resume-rejected")
            return
        }

        verificationHandoff = nil
        verificationOperationID = nil
        handoffDeadlineTask?.cancel()
        handoffDeadlineTask = nil
        runtime = handoff.runtime
        runtimeRevoked = false
        runtimeStartPending = false
        runtimeStartAttempted = true
        launchFailure = nil
        handoff.lease.end()
        state = .running
    }

    private func handoffLeaseDidEnd(_ token: UUID) {
        guard verificationHandoff?.token == token else { return }
        endVerificationHandoff(reason: "lease-expired")
    }

    private func endVerificationHandoff(reason: String) {
        guard let handoff = verificationHandoff else { return }

        // Revoke authority and invalidate every callback before calling any
        // injected cleanup code, which may synchronously notify the coordinator.
        verificationHandoff = nil
        verificationOperationID = nil
        handoffDeadlineTask?.cancel()
        handoffDeadlineTask = nil
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtime = nil

        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        if let request = activeAuthorization?.request { endAuthorization(request) }

        runtimeRevoked = true
        handoff.lease.end()
        handoff.runtime.revoke()
        if reason == "ended" {
            launchFailure = nil
        } else {
            launchFailure = "stage=verification-handoff; reason=" + reason
        }
        state = .ended
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
        if let handoff = verificationHandoff {
            // A handoff is the only exception to ordinary lifecycle revocation.
            // Lifecycle transitions still synchronously hide the controller,
            // cancel boundary work, and invalidate presentation/resume tokens.
            if handoff.resumePending {
                endVerificationHandoff(reason: "stale-resume")
                return
            }

            showingGuest = false
            presentationRequest = nil
            runtimeStartPending = false
            verificationOperationID = nil

            if let request = activeAuthorization?.request { endAuthorization(request) }
            activeCheckTask?.cancel()
            activeCheckTask = nil
            activeRequest = nil
            state = .holding

            return
        }

        // Hide access before invoking the adapter's revoke implementation.
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        if let runtime {
            runtime.revoke()
            runtimeRevoked = true
        }

        if let request = activeAuthorization?.request { endAuthorization(request) }
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
