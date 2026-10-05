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

/// An optional terminal-state signal for runtimes that can end independently
/// of the host. The callback must be delivered on the main actor.
@MainActor
public protocol NativeGuestTerminationReportingRuntime: NativeGuestRuntime {
    var terminationHandler: (@MainActor () -> Void)? { get set }
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

/// A diagnostic-only signal bridge. A true return value means only that the
/// adapter submitted the operating-system request; it does not prove that the
/// guest paused, resumed, or stopped media.
@MainActor
public protocol NativeGuestSignalDiagnosticRuntime: NativeGuestRuntime {
    var signalDiagnosticAvailable: Bool { get }
    func requestSignalDiagnosticPause() -> Bool
    func requestSignalDiagnosticResume() -> Bool
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
    private let signalDiagnosticDuration: Duration
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
    private var runtimeInstanceToken: UUID?
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
    private struct SignalDiagnosticHandoff {
        let token: UUID
        let originatingSession: SessionContext
        let runtime: any NativeGuestSignalDiagnosticRuntime
        let lease: any NativeGuestHandoffLease
        let deadline: ContinuousClock.Instant
        var pauseRequestSubmitted: Bool
        var resumePending = false
    }
    private var verificationHandoff: VerificationHandoff?
    private var handoffDeadlineTask: Task<Void, Never>?
    private var verificationOperationID: UUID?
    private var signalDiagnosticHandoff: SignalDiagnosticHandoff?
    private var signalDiagnosticDeadlineTask: Task<Void, Never>?
    private var signalDiagnosticAttemptConsumed = false
    private var signalDiagnosticReport: String?

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
        self.signalDiagnosticDuration = .seconds(30)
        self.state = runtimeFactory == nil ? .unavailable : .idle

        observeLifecycle()
    }

    internal init(
        lifecycle: SessionLifecycleCoordinator,
        check: @escaping @Sendable (Bool) async throws -> Void,
        runtimeFactory: (@MainActor () throws -> any NativeGuestRuntime)?,
        authorizationFactory: (@MainActor () -> any NativeGuestCredentialAuthorization)? = nil,
        leaseFactory: (@MainActor (@escaping @MainActor () -> Void) -> (any NativeGuestHandoffLease)?)? = nil,
        handoffDuration: Duration,
        signalDiagnosticDuration: Duration = .seconds(30)
    ) {
        self.lifecycle = lifecycle
        self.checkLegacyCredentialAbsence = check
        self.runtimeFactory = runtimeFactory
        self.authorizationFactory = authorizationFactory
        self.handoffLeaseFactory = leaseFactory
        self.handoffDuration = min(handoffDuration, .seconds(120))
        self.signalDiagnosticDuration = Self.boundedSignalDiagnosticDuration(signalDiagnosticDuration)
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
        return runtime?.viewController
            ?? verificationHandoff?.runtime.viewController
            ?? signalDiagnosticHandoff?.runtime.viewController
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

    /// Opt-in diagnostic affordance for runtimes that can submit a signal
    /// request. This is deliberately separate from the verified handoff gate.
    public var canBeginSignalDiagnostic: Bool {
        guard state == .running, showingGuest, !runtimeRevoked,
              !signalDiagnosticAttemptConsumed,
              presentationRequest.map({ isValid($0.session) }) == true,
              handoffLeaseFactory != nil,
              let diagnosticRuntime = runtime as? any NativeGuestSignalDiagnosticRuntime else { return false }
        return diagnosticRuntime.signalDiagnosticAvailable
    }

    /// Internal mount point retained while the guest is hidden during a hold.
    /// It never grants interaction or public presentation authority.
    internal var mountedViewController: UIViewController? {
        guard !runtimeRevoked,
              (showingGuest && presentationRequest.map { isValid($0.session) } == true)
                || verificationHandoff != nil
                || signalDiagnosticHandoff != nil else { return nil }
        return runtime?.viewController
            ?? verificationHandoff?.runtime.viewController
            ?? signalDiagnosticHandoff?.runtime.viewController
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

    /// Resume uses the same credential inventory check as initial launch. The
    /// pause signal's submission is not treated as suspension acknowledgement.
    public var canResumeSignalDiagnostic: Bool {
        guard let handoff = signalDiagnosticHandoff,
              handoff.pauseRequestSubmitted,
              !handoff.resumePending,
              activeRequest == nil,
              state == .holding || state == .blocked,
              handoff.lease.isValid,
              ContinuousClock().now < handoff.deadline,
              let session = validSessionContext(),
              session != handoff.originatingSession else { return false }
        return true
    }

    public var isSignalDiagnosticHeld: Bool { signalDiagnosticHandoff != nil }

    public var isSignalDiagnosticPauseRequestSubmitted: Bool {
        signalDiagnosticHandoff?.pauseRequestSubmitted == true
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
            if let signalDiagnosticReport {
                let runtimeSummary = runtime?.summary
                    ?? verificationHandoff?.runtime.summary
                    ?? signalDiagnosticHandoff?.runtime.summary
                return runtimeSummary.map { signalDiagnosticReport + "\n\n" + $0 }
                    ?? signalDiagnosticReport
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
            if let signalDiagnosticHandoff {
                return signalDiagnosticHandoff.pauseRequestSubmitted
                    ? "Pause signal request submitted; guest suspension and media stop are unproved."
                    : "Signal diagnostic is pending; guest suspension and media stop are unproved."
            }
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

        if let handoff = signalDiagnosticHandoff {
            guard !handoff.resumePending,
                  state == .holding || state == .blocked else { return nil }
            guard handoff.pauseRequestSubmitted,
                  handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline else {
                endSignalDiagnostic(reason: "lease-expired")
                return nil
            }
            guard session != handoff.originatingSession else { return nil }
        } else if let handoff = verificationHandoff {
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

    /// Conceals the guest, locks the private workspace at the host, and submits
    /// one bounded diagnostic pause request. No acknowledgement is claimed.
    @discardableResult
    public func beginSignalDiagnostic() -> Bool {
        guard state == .running, showingGuest, !runtimeRevoked,
              !signalDiagnosticAttemptConsumed,
              presentationRequest.map({ isValid($0.session) }) == true else { return false }
        signalDiagnosticAttemptConsumed = true
        guard let diagnosticRuntime = runtime as? any NativeGuestSignalDiagnosticRuntime,
              diagnosticRuntime.signalDiagnosticAvailable else {
            launchFailure = "stage=signal-diagnostic; reason=unsupported"
            return false
        }
        guard let leaseFactory = handoffLeaseFactory else {
            endRuntimePresentation()
            launchFailure = "stage=signal-diagnostic; reason=lease-unavailable"
            return false
        }

        let token = UUID()
        var leaseInvalidatedDuringCreation = false
        guard let lease = leaseFactory({ [weak self] in
            leaseInvalidatedDuringCreation = true
            self?.signalDiagnosticLeaseDidEnd(token)
        }) else {
            endRuntimePresentation()
            launchFailure = "stage=signal-diagnostic; reason=lease-unavailable"
            return false
        }
        guard lease.isValid, !leaseInvalidatedDuringCreation else {
            lease.end()
            endRuntimePresentation()
            launchFailure = "stage=signal-diagnostic; reason=lease-unavailable"
            return false
        }
        guard let originatingSession = presentationRequest?.session else {
            lease.end()
            endRuntimePresentation()
            return false
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: signalDiagnosticDuration)
        signalDiagnosticHandoff = SignalDiagnosticHandoff(
            token: token,
            originatingSession: originatingSession,
            runtime: diagnosticRuntime,
            lease: lease,
            deadline: deadline,
            pauseRequestSubmitted: false
        )

        // Remove all presentation authority before invoking the signal bridge.
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtimeStartAttempted = true
        self.runtime = nil
        runtimeRevoked = false
        launchFailure = nil
        signalDiagnosticReport = nil
        state = .holding
        signalDiagnosticDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard self?.signalDiagnosticHandoff?.token == token else { return }
            self?.endSignalDiagnostic(reason: "lease-expired")
        }

        let submitted = diagnosticRuntime.requestSignalDiagnosticPause()
        guard let active = signalDiagnosticHandoff, active.token == token else { return false }
        guard active.lease.isValid, ContinuousClock().now < active.deadline else {
            endSignalDiagnostic(reason: "lease-expired")
            return false
        }
        guard submitted else {
            endSignalDiagnostic(reason: "pause-request-rejected")
            return false
        }
        signalDiagnosticHandoff?.pauseRequestSubmitted = true
        signalDiagnosticReport = "Native guest signal diagnostic\nPause request submitted. Submission is not an acknowledgement; guest suspension and media stop are unproved."
        return true
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
        if signalDiagnosticHandoff != nil {
            endSignalDiagnostic(reason: "ended")
            return
        }
        if verificationHandoff != nil {
            endVerificationHandoff(reason: "ended")
            return
        }

        let authorizationRequest = activeAuthorization?.request
        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        endRuntimePresentation()
        if let authorizationRequest { endAuthorization(authorizationRequest) }
    }

    /// Call after the full-screen host has attached the authorized controller.
    /// Repeated calls never start the runtime twice.
    public func surfaceReady() {
        guard state == .presenting,
              showingGuest,
              !runtimeRevoked else { return }

        if let handoff = signalDiagnosticHandoff {
            guard handoff.pauseRequestSubmitted,
                  !handoff.resumePending,
                  handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline,
                  let presentationRequest = self.presentationRequest,
                  presentationRequest.session != handoff.originatingSession,
                  isValid(presentationRequest.session) else {
                if let handoff = signalDiagnosticHandoff,
                   (!handoff.lease.isValid || ContinuousClock().now >= handoff.deadline) {
                    endSignalDiagnostic(reason: "lease-expired")
                }
                return
            }

            signalDiagnosticHandoff?.resumePending = true
            let submitted = handoff.runtime.requestSignalDiagnosticResume()
            guard let active = signalDiagnosticHandoff, active.token == handoff.token else { return }
            guard active.resumePending,
                  let currentRequest = self.presentationRequest,
                  currentRequest == presentationRequest,
                  showingGuest,
                  state == .presenting,
                  isValid(presentationRequest.session) else {
                endSignalDiagnostic(reason: "stale-resume")
                return
            }
            guard active.lease.isValid, ContinuousClock().now < active.deadline else {
                endSignalDiagnostic(reason: "lease-expired")
                return
            }
            guard submitted else {
                endSignalDiagnostic(reason: "resume-request-rejected")
                return
            }

            signalDiagnosticHandoff = nil
            signalDiagnosticDeadlineTask?.cancel()
            signalDiagnosticDeadlineTask = nil
            runtime = handoff.runtime
            runtimeRevoked = false
            runtimeStartPending = false
            runtimeStartAttempted = true
            launchFailure = nil
            signalDiagnosticReport = "Native guest signal diagnostic\nPause request submitted; suspension and media stop are unproved.\nResume request submitted; runtime resumption and visible content are unproved."
            state = .running
            // End the lease after committing the transfer so a synchronous
            // lease callback can still lock/revoke the newly presented runtime.
            handoff.lease.end()
            return
        }

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
            && (!runtimeAttemptConsumed || verificationHandoff != nil || signalDiagnosticHandoff != nil)
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
            state = (verificationHandoff == nil && signalDiagnosticHandoff == nil) ? .idle : .holding
            return
        }
        if let failure {
            launchFailure = failure
            state = .blocked
            return
        }

        if let handoff = signalDiagnosticHandoff {
            guard handoff.pauseRequestSubmitted,
                  handoff.lease.isValid,
                  ContinuousClock().now < handoff.deadline,
                  request.session != handoff.originatingSession else {
                endSignalDiagnostic(reason: "lease-expired")
                return
            }

            runtimeRevoked = false
            runtimeStartPending = false
            presentationRequest = request
            showingGuest = true
            state = .presenting
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
            let runtimeToken = UUID()
            runtimeInstanceToken = runtimeToken
            runtimeRevoked = false
            if let reportingRuntime = createdRuntime as? any NativeGuestTerminationReportingRuntime {
                reportingRuntime.terminationHandler = { [weak self] in
                    self?.runtimeDidTerminate(token: runtimeToken)
                }
            }

            // Setting the reporting callback is injected runtime code and may
            // synchronously report termination. Do not continue into a stale
            // presentation path if that happened during installation.
            guard runtimeInstanceToken == runtimeToken, !runtimeRevoked else { return }
            guard isValid(request.session) else {
                showingGuest = false
                presentationRequest = nil
                runtimeStartPending = false
                state = .ended
                revokeRuntime(createdRuntime, evenIfPreviouslyRevoked: true)
                return
            }

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
        activeRequest = nil
        activeCheckTask = nil
        state = (verificationHandoff != nil || signalDiagnosticHandoff != nil)
            ? .holding
            : (runtimeFactory == nil ? .unavailable : .idle)
        endAuthorization(request)
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
            state = .blocked
            if let runtime { revokeRuntime(runtime) }
        }
    }

    private func runtimeDidTerminate(token: UUID) {
        guard runtimeInstanceToken == token else { return }

        let endedRuntime = runtime
            ?? verificationHandoff?.runtime
            ?? signalDiagnosticHandoff?.runtime
        guard let endedRuntime else {
            runtimeInstanceToken = nil
            return
        }

        let heldLease = verificationHandoff?.lease ?? signalDiagnosticHandoff?.lease

        // Revoke presentation, request, resume, and callback authority before
        // asking any injected object to end or revoke itself.
        runtimeInstanceToken = nil
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        activeRequest = nil
        activeCheckTask?.cancel()
        activeCheckTask = nil
        verificationOperationID = nil
        verificationHandoff = nil
        signalDiagnosticHandoff = nil
        handoffDeadlineTask?.cancel()
        handoffDeadlineTask = nil
        signalDiagnosticDeadlineTask?.cancel()
        signalDiagnosticDeadlineTask = nil

        // Keep the terminated runtime only for its existing authenticated
        // diagnostic summary. All controller access is now revoked.
        runtime = endedRuntime
        runtimeRevoked = true
        launchFailure = "stage=runtime-termination; reason=guest-ended"
        state = .ended

        if let request = activeAuthorization?.request { endAuthorization(request) }
        heldLease?.end()
        revokeRuntime(endedRuntime, evenIfPreviouslyRevoked: true)
    }

    private func revokeRuntime(
        _ runtime: any NativeGuestRuntime,
        evenIfPreviouslyRevoked: Bool = false
    ) {
        // A runtime may synchronously call its terminal handler from revoke().
        // Invalidate the instance token before crossing that boundary.
        runtimeInstanceToken = nil
        guard evenIfPreviouslyRevoked || !runtimeRevoked else { return }
        runtimeRevoked = true
        runtime.revoke()
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
        state = .running
        handoff.lease.end()
    }

    private func handoffLeaseDidEnd(_ token: UUID) {
        guard verificationHandoff?.token == token else { return }
        endVerificationHandoff(reason: "lease-expired")
    }

    private func signalDiagnosticLeaseDidEnd(_ token: UUID) {
        guard signalDiagnosticHandoff?.token == token else { return }
        endSignalDiagnostic(reason: "lease-expired")
    }

    private func endSignalDiagnostic(reason: String) {
        guard let handoff = signalDiagnosticHandoff else { return }

        // Invalidate every public and asynchronous authority before adapter code.
        let authorizationRequest = activeAuthorization?.request
        runtimeInstanceToken = nil
        signalDiagnosticHandoff = nil
        signalDiagnosticDeadlineTask?.cancel()
        signalDiagnosticDeadlineTask = nil
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtime = nil
        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        runtimeRevoked = true
        launchFailure = reason == "ended"
            ? nil
            : "stage=signal-diagnostic; reason=" + reason
        state = .ended
        if let authorizationRequest { endAuthorization(authorizationRequest) }
        handoff.lease.end()
        revokeRuntime(handoff.runtime, evenIfPreviouslyRevoked: true)
    }

    private func endVerificationHandoff(reason: String) {
        guard let handoff = verificationHandoff else { return }

        // Revoke authority and invalidate every callback before calling any
        // injected cleanup code, which may synchronously notify the coordinator.
        let authorizationRequest = activeAuthorization?.request
        runtimeInstanceToken = nil
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

        runtimeRevoked = true
        if reason == "ended" {
            launchFailure = nil
        } else {
            launchFailure = "stage=verification-handoff; reason=" + reason
        }
        state = .ended
        if let authorizationRequest { endAuthorization(authorizationRequest) }
        handoff.lease.end()
        revokeRuntime(handoff.runtime, evenIfPreviouslyRevoked: true)
    }

    private func endRuntimePresentation() {
        let runtimeToRevoke = runtime
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtimeInstanceToken = nil
        if runtimeToRevoke != nil { runtimeRevoked = true }
        if runtimeAttemptConsumed {
            state = .ended
        }
        runtimeToRevoke?.revoke()
    }

    private func invalidateForLifecycleTransition() {
        if let handoff = signalDiagnosticHandoff {
            // Preserve only the manually paused, concealed diagnostic. A
            // lifecycle change during resume makes runtime state uncertain.
            if handoff.resumePending {
                endSignalDiagnostic(reason: "stale-resume")
                return
            }

            let authorizationRequest = activeAuthorization?.request
            showingGuest = false
            presentationRequest = nil
            runtimeStartPending = false
            activeCheckTask?.cancel()
            activeCheckTask = nil
            activeRequest = nil
            state = .holding
            if let authorizationRequest { endAuthorization(authorizationRequest) }
            return
        }

        if let handoff = verificationHandoff {
            // A handoff is the only exception to ordinary lifecycle revocation.
            // Lifecycle transitions still synchronously hide the controller,
            // cancel boundary work, and invalidate presentation/resume tokens.
            if handoff.resumePending {
                endVerificationHandoff(reason: "stale-resume")
                return
            }

            let authorizationRequest = activeAuthorization?.request
            showingGuest = false
            presentationRequest = nil
            runtimeStartPending = false
            verificationOperationID = nil
            activeCheckTask?.cancel()
            activeCheckTask = nil
            activeRequest = nil
            state = .holding
            if let authorizationRequest { endAuthorization(authorizationRequest) }

            return
        }

        // Retry the idempotent revoke for every lifecycle transition. The
        // lifecycle publishes `.locking` and `.calculatorLocked` separately.
        let authorizationRequest = activeAuthorization?.request
        let runtimeToRevoke = runtime
        showingGuest = false
        presentationRequest = nil
        runtimeStartPending = false
        runtimeInstanceToken = nil
        if runtimeToRevoke != nil { runtimeRevoked = true }

        activeCheckTask?.cancel()
        activeCheckTask = nil
        activeRequest = nil
        state = runtimeAttemptConsumed ? .ended : (runtimeFactory == nil ? .unavailable : .idle)
        if let authorizationRequest { endAuthorization(authorizationRequest) }
        runtimeToRevoke?.revoke()
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

    static func boundedSignalDiagnosticDuration(_ duration: Duration) -> Duration {
        min(duration, .seconds(30))
    }
}
