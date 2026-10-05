import UIKit
import XCTest
@testable import CalcVault

@MainActor
final class NativeGuestCoordinatorTests: XCTestCase {
    func testLockedAndAuthenticatingSessionsCannotStartCheck() async {
        let lifecycle = SessionLifecycleCoordinator()
        let checker = SuspendedGuestChecker()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: FakeGuestRuntime())

        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertNil(coordinator.start(biometricEnabled: true))
        XCTAssertEqual(coordinator.state, .blocked)

        lifecycle.beginAuthentication()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        XCTAssertEqual(coordinator.state, .blocked)

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testActiveSessionRunsCheckBeforeCreatingRuntime() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)

        XCTAssertTrue(coordinator.canRequestLaunch)
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        XCTAssertEqual(coordinator.state, .checking)
        XCTAssertFalse(coordinator.canRequestLaunch)
        await checker.waitForCall(1)
        XCTAssertEqual(runtime.factoryCount, 0)

        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertTrue(coordinator.showingGuest)
        XCTAssertNotNil(coordinator.viewController)
    }

    func testDuplicateCheckIsRejected() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: FakeGuestRuntime())

        let first = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        XCTAssertNil(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await first.value
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testLockDuringCheckCancelsAndRejectsLateSuccess() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)

        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        lifecycle.lock()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.showingGuest)

        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testExplicitTaskCancellationCannotCreateRuntime() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)

        let task = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(1)
        task.cancel()
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(runtime.factoryCount, 0)
    }

    func testStaleCheckCannotAuthorizeFreshSession() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)

        let staleTask = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let currentTask = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(2)

        let staleResolved = await checker.succeed(1)
        XCTAssertTrue(staleResolved)
        await staleTask.value
        XCTAssertEqual(coordinator.state, .checking)
        XCTAssertEqual(runtime.factoryCount, 0)

        let currentResolved = await checker.succeed(2)
        XCTAssertTrue(currentResolved)
        await currentTask.value
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertEqual(runtime.factoryCount, 1)
    }

    func testSurfaceReadyStartsRuntimeOnlyOnce() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)

        coordinator.surfaceReady()
        coordinator.surfaceReady()

        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertTrue(coordinator.showingGuest)
    }

    func testLockWhileStartPendingRejectsLateRuntimeCallback() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.startCount, 1)

        lifecycle.lock()
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        // lock() publishes .locking and then .calculatorLocked. Both must
        // synchronously revoke; the runtime contract is intentionally idempotent.
        XCTAssertEqual(runtime.revokeCount, 2)
        XCTAssertEqual(coordinator.state, .ended)

        runtime.completeStart(true)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertEqual(runtime.revokeCount, 3)
    }

    func testRunningGuestIsHiddenAndRevokedOnLock() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        runtime.completeStart(true)
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertNotNil(coordinator.viewController)

        lifecycle.lock()

        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.revokeCount, 2)
    }

    func testRetainedSummaryReturnsAfterReauthenticationWithoutRestoringController() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        runtime.completeStart(true)
        XCTAssertEqual(coordinator.summary, runtime.summary)

        lifecycle.lock()
        XCTAssertNil(coordinator.viewController)
        XCTAssertFalse(coordinator.summary.contains("Guest runtime is ready"))

        _ = try unlock(lifecycle)
        XCTAssertEqual(coordinator.summary, runtime.summary)
        XCTAssertNil(coordinator.viewController)
        XCTAssertFalse(coordinator.showingGuest)
    }

    func testFactorySessionChangeRevokesRuntimeBeforePresentation() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: {
                runtime.noteFactoryInvocation()
                lifecycle.lock()
                return runtime
            }
        )

        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.revokeCount, 1)
    }

    func testThrowingFactoryConsumesTheRuntimeAttempt() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: {
                runtime.noteFactoryInvocation()
                throw SyntheticFactoryFailure.failed
            }
        )

        try await completeCheck(coordinator, checker: checker)
        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertFalse(coordinator.showingGuest)

        lifecycle.lock()
        _ = try unlock(lifecycle)
        XCTAssertNil(coordinator.start(biometricEnabled: true))

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
    }

    func testRuntimeStartFailureRevokesAndBlocks() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        runtime.completeStart(false)

        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.revokeCount, 1)
    }

    func testRuntimeAttemptCannotBeReusedAfterFreshAuthentication() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        lifecycle.lock()
        _ = try unlock(lifecycle)

        XCTAssertNil(coordinator.start(biometricEnabled: true))
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
    }

    func testMissingFactoryIsUnavailableAndDoesNotCheck() async {
        let lifecycle = SessionLifecycleCoordinator()
        let checker = SuspendedGuestChecker()
        let coordinator = NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                _ = biometricEnabled
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: nil
        )

        XCTAssertEqual(coordinator.state, .unavailable)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        XCTAssertFalse(coordinator.showingGuest)
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testCheckerFailureIsSanitizedAndCanBeRetried() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)

        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        let resolved = await checker.fail(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertFalse(coordinator.summary.contains("sensitive"))
        XCTAssertTrue(coordinator.summary.contains("stage=credential-boundary; unclassified"))
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertTrue(coordinator.canRequestLaunch)

        let retryTask = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        XCTAssertFalse(coordinator.canRequestLaunch)
        await checker.waitForCall(2)
        let retryResolved = await checker.succeed(2)
        XCTAssertTrue(retryResolved)
        await retryTask.value
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertFalse(coordinator.canRequestLaunch)
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertFalse(coordinator.summary.contains("stage=credential-boundary"))
    }

    func testPreparationDiagnosticIsAllowlistedAndRequiresAuthentication() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let coordinator = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in }, runtimeFactory: {
            throw NativeGuestPreparationFailure.immutableContract
        })
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await task.value
        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertEqual(coordinator.summary,
                       "Native launch diagnostic v1\nstage=runtime-preparation; reason=immutable-framework-contract")
        lifecycle.lock()
        XCTAssertFalse(coordinator.summary.contains("immutable-framework-contract"))
        _ = try unlock(lifecycle)
        XCTAssertTrue(coordinator.summary.contains("immutable-framework-contract"))
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        XCTAssertNil(coordinator.viewController)
    }

    func testUnknownFactoryErrorDoesNotExposeDescriptionOrUserInfo() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let coordinator = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in }, runtimeFactory: {
            throw NSError(domain: "sensitive-domain", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "sensitive-path-and-credential"])
        })
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await task.value
        XCTAssertEqual(coordinator.summary,
                       "Native launch diagnostic v1\nstage=runtime-preparation; reason=unclassified")
        XCTAssertFalse(coordinator.summary.contains("sensitive"))
    }

    func testTypedCredentialDiagnosticSurvivesWithoutConstructingRuntime() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let runtime = FakeGuestRuntime()
        let coordinator = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in
            // Invalid synthetic inventory is rejected before any Keychain query.
            try HostOnlyKeychainStorage().assertGuestCredentialBoundary(
                required: [], optional: [], diagnosticErrors: true)
        }, runtimeFactory: {
            runtime.noteFactoryInvocation()
            return runtime
        })
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await task.value
        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertTrue(coordinator.summary.contains("stage=credential-boundary"))
        XCTAssertTrue(coordinator.summary.contains("native-guest-boundary.inventory.invalid-inventory"))
        lifecycle.lock()
        XCTAssertFalse(coordinator.summary.contains("native-guest-boundary"))
    }

    func testLateCheckFailureCannotReplaceNewSessionReport() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        let stale = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let current = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let success = await checker.succeed(2)
        XCTAssertTrue(success)
        await current.value
        let failure = await checker.fail(1)
        XCTAssertTrue(failure)
        await stale.value
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertEqual(coordinator.summary, runtime.summary)
    }

    func testRuntimeRejectionReportKeepsItsStageAndRuntimeEvidence() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        runtime.completeStart(false)
        XCTAssertTrue(coordinator.summary.contains("stage=runtime-start; reason=request-rejected"))
        XCTAssertTrue(coordinator.summary.contains(runtime.summary))
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.revokeCount, 1)
    }

    func testHandoffCanBeginOnlyForRunningVerificationCapableRuntime() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )

        XCTAssertFalse(coordinator.canBeginVerificationHandoff)
        XCTAssertFalse(coordinator.beginVerificationHandoff())
        try await completeCheck(coordinator, checker: checker)
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertFalse(coordinator.beginVerificationHandoff())
        coordinator.surfaceReady()
        runtime.completeStart(true)
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertTrue(coordinator.canBeginVerificationHandoff)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNotNil(coordinator.mountedViewController)
        XCTAssertFalse(coordinator.canResumeVerification)
        XCTAssertTrue(coordinator.summary.contains("handoff is pending"))
        runtime.completeSuspend(true)
        XCTAssertTrue(coordinator.summary.contains("held for verification"))
    }

    func testUnsupportedRuntimeAndMissingLeaseFailVisiblyWithoutHolding() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeGuestRuntime()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: runtime)
        try await completeCheck(coordinator, checker: checker)
        coordinator.surfaceReady()
        runtime.completeStart(true)

        XCTAssertFalse(coordinator.canBeginVerificationHandoff)
        XCTAssertFalse(coordinator.beginVerificationHandoff())
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertTrue(coordinator.showingGuest)
        XCTAssertTrue(coordinator.summary.contains("stage=verification-handoff; reason=unsupported"))
    }

    func testLifecycleLockRetainsOnlyHiddenAcknowledgedHandoff() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)

        lifecycle.lock()
        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNotNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 0)
        XCTAssertEqual(lease.endCount, 0)
        XCTAssertFalse(coordinator.canResumeVerification)
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)

        _ = try unlock(lifecycle)
        XCTAssertTrue(coordinator.canResumeVerification)
    }

    func testResumeRequiresFreshCredentialCheckAndDoesNotRestartRuntime() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        XCTAssertTrue(coordinator.canResumeVerification)

        let resumeCheck = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(2)
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.resumeCount, 0)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await resumeCheck.value
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertEqual(runtime.resumeCount, 0)
        XCTAssertTrue(coordinator.showingGuest)
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        runtime.completeSuspend(false)
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertEqual(runtime.revokeCount, 0)

        coordinator.surfaceReady()
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertTrue(runtime.isSuspended)
        runtime.completeResume(true)
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertFalse(runtime.isSuspended)
        XCTAssertEqual(lease.endCount, 1)
        XCTAssertFalse(coordinator.canResumeVerification)
    }

    func testLeaseExpiryRevokesHeldRuntimeAndInvalidatesCallbacks() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        lease.expire()

        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        runtime.completeSuspend(true)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertEqual(runtime.revokeCount, 1)
    }

    func testSuspensionFailureRevokesWithoutEnteringResumeState() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())

        runtime.completeSuspend(false)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.canResumeVerification)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testSynchronouslyExpiredFactoryLeaseIsEndedWithoutStartingHandoff() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease(expiresDuringInstall: true)
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)

        XCTAssertFalse(coordinator.beginVerificationHandoff())
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertTrue(coordinator.showingGuest)
        XCTAssertEqual(runtime.suspendCount, 0)
        XCTAssertEqual(runtime.revokeCount, 0)
        XCTAssertEqual(lease.endCount, 1)
        XCTAssertTrue(coordinator.summary.contains("reason=lease-unavailable"))
    }

    func testMonotonicDeadlineExpiresUnacknowledgedPause() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle,
            checker: checker,
            runtime: runtime,
            lease: lease,
            handoffDuration: .milliseconds(20)
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())

        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.canResumeVerification)
        XCTAssertEqual(runtime.revokeCount, 1)
        runtime.completeSuspend(true)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertNil(coordinator.viewController)
    }

    func testDuplicateLifecycleEventsDoNotExtendHandoffDeadline() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle,
            checker: checker,
            runtime: runtime,
            lease: lease,
            handoffDuration: .milliseconds(100)
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)

        try await Task.sleep(nanoseconds: 50_000_000)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertTrue(coordinator.canResumeVerification)

        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testExplicitProtectedEndTerminatesHandoffBeforeLifecycleLock() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)

        coordinator.endVerificationHandoff()
        lifecycle.lock()
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        runtime.completeSuspend(true)
        XCTAssertEqual(coordinator.state, .ended)
    }

    func testLateResumeCallbackAfterLeaseExpiryCannotRestorePresentation() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await task.value
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeCount, 1)

        lease.expire()
        runtime.completeResume(true)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
    }

    func testLifecycleLockDuringPendingResumeHardRevokesAndRejectsLateCallback() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await task.value
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeCount, 1)

        lifecycle.lock()
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        runtime.completeResume(true)
        _ = try unlock(lifecycle)
        XCTAssertFalse(coordinator.canResumeVerification)
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        XCTAssertEqual(coordinator.state, .ended)
    }

    func testCancelledAndStaleResumeChecksCannotPresentGuest() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeVerificationGuestRuntime()
        let lease = FakeGuestHandoffLease()
        let coordinator = makeHandoffCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startVerificationGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginVerificationHandoff())
        runtime.completeSuspend(true)
        lifecycle.lock()
        _ = try unlock(lifecycle)

        let cancelled = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        cancelled.cancel()
        let cancelledCheckSucceeded = await checker.succeed(2)
        XCTAssertTrue(cancelledCheckSucceeded)
        await cancelled.value
        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertNil(coordinator.viewController)

        lifecycle.lock()
        _ = try unlock(lifecycle)
        let stale = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(3)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let staleCheckSucceeded = await checker.succeed(3)
        XCTAssertTrue(staleCheckSucceeded)
        await stale.value
        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertNil(coordinator.viewController)
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(runtime.startCount, 1)
    }

    func testSignalDiagnosticDefaultsOffAndDoesNotClaimVerifiedCapability() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let unsupported = FakeGuestRuntime()
        let unsupportedCoordinator = makeCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: unsupported
        )
        try await completeCheck(unsupportedCoordinator, checker: checker)
        unsupportedCoordinator.surfaceReady()
        unsupported.completeStart(true)
        XCTAssertFalse(unsupportedCoordinator.canBeginSignalDiagnostic)
        XCTAssertFalse(unsupportedCoordinator.canBeginVerificationHandoff)

        lifecycle.lock()
        _ = try unlock(lifecycle)
        let signalRuntime = FakeSignalDiagnosticGuestRuntime(available: true)
        let signalCoordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: signalRuntime,
            lease: FakeGuestHandoffLease()
        )
        try await startSignalDiagnosticGuest(signalCoordinator, checker: checker, runtime: signalRuntime)

        XCTAssertTrue(signalCoordinator.canBeginSignalDiagnostic)
        XCTAssertFalse(signalCoordinator.canBeginVerificationHandoff)
        XCTAssertFalse(signalRuntime is any NativeGuestVerificationRuntime)
    }

    func testSignalDiagnosticRequiresLeaseAndRevokesIfExplicitAttemptHasNoLease() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let noLeaseCoordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: nil
        )
        try await startSignalDiagnosticGuest(noLeaseCoordinator, checker: checker, runtime: runtime)
        XCTAssertFalse(noLeaseCoordinator.canBeginSignalDiagnostic)
        XCTAssertFalse(noLeaseCoordinator.beginSignalDiagnostic())
        XCTAssertEqual(noLeaseCoordinator.state, .ended)
        XCTAssertFalse(noLeaseCoordinator.showingGuest)
        XCTAssertEqual(runtime.pauseRequestCount, 0)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertTrue(noLeaseCoordinator.summary.contains("lease-unavailable"))
    }

    func testSignalDiagnosticConcealsBeforeRequestAndReportsOnlySubmission() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)

        runtime.onPauseRequest = { [weak coordinator] in
            XCTAssertFalse(coordinator?.showingGuest ?? true)
            XCTAssertNil(coordinator?.viewController)
            XCTAssertNotNil(coordinator?.mountedViewController)
            XCTAssertTrue(coordinator?.summary.contains("Signal diagnostic is pending") ?? false)
            XCTAssertFalse(coordinator?.summary.contains("Pause request submitted") ?? true)
            XCTAssertFalse(coordinator?.isSignalDiagnosticPauseRequestSubmitted ?? true)
        }
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        XCTAssertEqual(runtime.pauseRequestCount, 1)
        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNotNil(coordinator.mountedViewController)
        XCTAssertFalse(coordinator.canResumeSignalDiagnostic)
        XCTAssertTrue(coordinator.isSignalDiagnosticPauseRequestSubmitted)
        XCTAssertFalse(coordinator.canBeginVerificationHandoff)
        XCTAssertTrue(coordinator.summary.contains("Pause request submitted"))
        XCTAssertTrue(coordinator.summary.contains("suspension and media stop are unproved"))
    }

    func testSignalDiagnosticPauseRejectionRevokesAndConsumesAttempt() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        runtime.pauseSubmission = false
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)

        XCTAssertFalse(coordinator.beginSignalDiagnostic())
        XCTAssertEqual(runtime.pauseRequestCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        XCTAssertFalse(coordinator.canBeginSignalDiagnostic)
        XCTAssertTrue(coordinator.summary.contains("pause-request-rejected"))
    }

    func testSignalDiagnosticDurationIsClampedTo30SecondsAndExpiryRevokes() async throws {
        XCTAssertEqual(
            NativeGuestCoordinator.boundedSignalDiagnosticDuration(.seconds(90)), .seconds(30)
        )
        XCTAssertEqual(
            NativeGuestCoordinator.boundedSignalDiagnosticDuration(.seconds(12)), .seconds(12)
        )

        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease,
            signalDiagnosticDuration: .milliseconds(20)
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())

        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testSignalDiagnosticCancellationNeverSubmitsResumeAndStaysConcealed() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        lifecycle.lock()
        _ = try unlock(lifecycle)

        let cancelledCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        cancelledCheck.cancel()
        let lateCheckSucceeded = await checker.succeed(2)
        XCTAssertTrue(lateCheckSucceeded)
        await cancelledCheck.value

        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNotNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertTrue(coordinator.canResumeSignalDiagnostic)
        coordinator.endVerificationHandoff()
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertEqual(coordinator.state, .ended)
    }

    func testSignalDiagnosticRejectsLeaseThatExpiresDuringCreation() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease(expiresDuringInstall: true)
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)

        XCTAssertFalse(coordinator.beginSignalDiagnostic())
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.pauseRequestCount, 0)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testSignalDiagnosticLeaseExpiryDuringPauseBridgeRevokesReentrantly() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        runtime.onPauseRequest = { lease.expire() }

        XCTAssertFalse(coordinator.beginSignalDiagnostic())
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.pauseRequestCount, 1)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testSignalDiagnosticNeedsFreshSessionAndSuccessfulCredentialCheckForManualResume() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        XCTAssertNil(coordinator.start(biometricEnabled: false))
        XCTAssertEqual(runtime.resumeRequestCount, 0)

        lifecycle.lock()
        _ = try unlock(lifecycle)
        XCTAssertTrue(coordinator.canResumeSignalDiagnostic)
        let resumeCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        XCTAssertEqual(coordinator.state, .checking)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertEqual(runtime.resumeRequestCount, 0)

        let failedCheck = await checker.fail(2)
        XCTAssertTrue(failedCheck)
        await resumeCheck.value
        XCTAssertEqual(coordinator.state, .blocked)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertTrue(coordinator.canResumeSignalDiagnostic)

        let retry = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(3)
        let retrySucceeded = await checker.succeed(3)
        XCTAssertTrue(retrySucceeded)
        await retry.value
        XCTAssertEqual(coordinator.state, .presenting)
        XCTAssertTrue(coordinator.showingGuest)
        XCTAssertEqual(runtime.resumeRequestCount, 0)

        coordinator.surfaceReady()
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeRequestCount, 1)
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        XCTAssertFalse(coordinator.canBeginSignalDiagnostic)
        XCTAssertFalse(coordinator.canResumeSignalDiagnostic)
        XCTAssertFalse(coordinator.beginSignalDiagnostic())
        XCTAssertEqual(runtime.pauseRequestCount, 1)
        XCTAssertTrue(coordinator.summary.contains("Resume request submitted"))
        XCTAssertTrue(coordinator.summary.contains("visible content are unproved"))
    }

    func testSignalDiagnosticNeverAutoResumesAndExplicitLockRevokes() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())

        lifecycle.applicationDidEnterBackground()
        lifecycle.applicationDidBecomeActive()
        _ = try unlock(lifecycle)
        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertTrue(coordinator.canResumeSignalDiagnostic)

        coordinator.endVerificationHandoff()
        lifecycle.lock()
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testSignalDiagnosticResumeRejectionRevokesGuest() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        runtime.resumeSubmission = false
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let resumeCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await resumeCheck.value

        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeRequestCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testLifecycleLockDuringResumeSubmissionRejectsStaleContinuation() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let resumeCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await resumeCheck.value

        runtime.onResumeRequest = { lifecycle.lock() }
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeRequestCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 1)
        XCTAssertEqual(lease.endCount, 1)
    }

    func testReentrantLeaseEndLockRevokesTheRestoredGuest() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let resumeCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        let checkSucceeded = await checker.succeed(2)
        XCTAssertTrue(checkSucceeded)
        await resumeCheck.value

        lease.onEndDuringEnd = { lifecycle.lock() }
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.resumeRequestCount, 1)
        XCTAssertEqual(lease.endCount, 1)
        XCTAssertEqual(coordinator.state, .ended)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.revokeCount, 2)
    }

    func testStaleResumeCheckCannotExposeGuestOrSubmitResume() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedGuestChecker()
        let runtime = FakeSignalDiagnosticGuestRuntime(available: true)
        let lease = FakeGuestHandoffLease()
        let coordinator = makeSignalDiagnosticCoordinator(
            lifecycle: lifecycle, checker: checker, runtime: runtime, lease: lease
        )
        try await startSignalDiagnosticGuest(coordinator, checker: checker, runtime: runtime)
        XCTAssertTrue(coordinator.beginSignalDiagnostic())
        lifecycle.lock()
        _ = try unlock(lifecycle)

        let staleCheck = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(2)
        lifecycle.lock()
        _ = try unlock(lifecycle)
        let staleCheckSucceeded = await checker.succeed(2)
        XCTAssertTrue(staleCheckSucceeded)
        await staleCheck.value

        XCTAssertEqual(coordinator.state, .holding)
        XCTAssertFalse(coordinator.showingGuest)
        XCTAssertNil(coordinator.viewController)
        XCTAssertNotNil(coordinator.mountedViewController)
        XCTAssertEqual(runtime.resumeRequestCount, 0)
        XCTAssertTrue(coordinator.canResumeSignalDiagnostic)
    }

    private func completeCheck(
        _ coordinator: NativeGuestCoordinator,
        checker: SuspendedGuestChecker
    ) async throws {
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value
    }

    private func makeCoordinator(
        lifecycle: SessionLifecycleCoordinator,
        checker: SuspendedGuestChecker,
        runtime: FakeGuestRuntime
    ) -> NativeGuestCoordinator {
        NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: {
                runtime.noteFactoryInvocation()
                return runtime
            }
        )
    }

    private func makeHandoffCoordinator(
        lifecycle: SessionLifecycleCoordinator,
        checker: SuspendedGuestChecker,
        runtime: FakeVerificationGuestRuntime,
        lease: FakeGuestHandoffLease,
        handoffDuration: Duration = .seconds(120)
    ) -> NativeGuestCoordinator {
        NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: {
                runtime.noteFactoryInvocation()
                return runtime
            },
            leaseFactory: { onEnd in
                lease.install(onEnd: onEnd)
                return lease
            },
            handoffDuration: handoffDuration
        )
    }

    private func makeSignalDiagnosticCoordinator(
        lifecycle: SessionLifecycleCoordinator,
        checker: SuspendedGuestChecker,
        runtime: any NativeGuestRuntime,
        lease: FakeGuestHandoffLease?,
        signalDiagnosticDuration: Duration = .seconds(30)
    ) -> NativeGuestCoordinator {
        let leaseFactory: (@MainActor (@escaping @MainActor () -> Void) -> (any NativeGuestHandoffLease)?)?
        if let lease {
            leaseFactory = { onEnd in
                lease.install(onEnd: onEnd)
                return lease
            }
        } else {
            leaseFactory = nil
        }
        return NativeGuestCoordinator(
            lifecycle: lifecycle,
            check: { biometricEnabled in
                try await checker.check(biometricEnabled: biometricEnabled)
            },
            runtimeFactory: {
                if let runtime = runtime as? FakeSignalDiagnosticGuestRuntime {
                    runtime.noteFactoryInvocation()
                } else if let runtime = runtime as? FakeGuestRuntime {
                    runtime.noteFactoryInvocation()
                }
                return runtime
            },
            leaseFactory: leaseFactory,
            handoffDuration: .seconds(120),
            signalDiagnosticDuration: signalDiagnosticDuration
        )
    }

    private func startVerificationGuest(
        _ coordinator: NativeGuestCoordinator,
        checker: SuspendedGuestChecker,
        runtime: FakeVerificationGuestRuntime
    ) async throws {
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        let checkSucceeded = await checker.succeed(1)
        XCTAssertTrue(checkSucceeded)
        await task.value
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.startCount, 1)
        runtime.completeStart(true)
        XCTAssertEqual(coordinator.state, .running)
    }

    private func startSignalDiagnosticGuest(
        _ coordinator: NativeGuestCoordinator,
        checker: SuspendedGuestChecker,
        runtime: FakeSignalDiagnosticGuestRuntime
    ) async throws {
        let task = try XCTUnwrap(coordinator.start(biometricEnabled: false))
        await checker.waitForCall(1)
        let checkSucceeded = await checker.succeed(1)
        XCTAssertTrue(checkSucceeded)
        await task.value
        coordinator.surfaceReady()
        XCTAssertEqual(runtime.startCount, 1)
        runtime.completeStart(true)
        XCTAssertEqual(coordinator.state, .running)
    }

    private func unlock(_ lifecycle: SessionLifecycleCoordinator) throws -> UUID {
        let attemptID = lifecycle.beginAuthentication()
        return try XCTUnwrap(lifecycle.completeAuthentication(attemptID: attemptID))
    }
}

@MainActor
private final class FakeGuestRuntime: NativeGuestRuntime {
    let viewController = UIViewController()
    let summary = "Guest runtime is ready."
    private(set) var factoryCount = 0
    private(set) var startCount = 0
    private(set) var revokeCount = 0
    private var completion: (@MainActor (Bool) -> Void)?

    func noteFactoryInvocation() {
        factoryCount += 1
    }

    func start(completion: @escaping @MainActor (Bool) -> Void) {
        startCount += 1
        self.completion = completion
    }

    func revoke() {
        revokeCount += 1
    }

    func completeStart(_ started: Bool) {
        completion?(started)
    }
}

@MainActor
private final class FakeVerificationGuestRuntime: NativeGuestVerificationRuntime {
    let viewController = UIViewController()
    let summary = "Verification guest is ready."
    private(set) var factoryCount = 0
    private(set) var startCount = 0
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var revokeCount = 0
    private(set) var isSuspended = false
    private var startCompletion: (@MainActor (Bool) -> Void)?
    private var suspendCompletion: (@MainActor (Bool) -> Void)?
    private var resumeCompletion: (@MainActor (Bool) -> Void)?

    func noteFactoryInvocation() {
        factoryCount += 1
    }

    func start(completion: @escaping @MainActor (Bool) -> Void) {
        startCount += 1
        startCompletion = completion
    }

    func suspendForVerification(completion: @escaping @MainActor (Bool) -> Void) {
        suspendCount += 1
        isSuspended = true
        suspendCompletion = completion
    }

    func resumeAfterVerification(completion: @escaping @MainActor (Bool) -> Void) {
        resumeCount += 1
        resumeCompletion = completion
    }

    func revoke() {
        revokeCount += 1
        isSuspended = true
    }

    func completeStart(_ started: Bool) {
        startCompletion?(started)
    }

    func completeSuspend(_ suspended: Bool) {
        suspendCompletion?(suspended)
    }

    func completeResume(_ resumed: Bool) {
        if resumed { isSuspended = false }
        resumeCompletion?(resumed)
    }
}

@MainActor
private final class FakeSignalDiagnosticGuestRuntime: NativeGuestSignalDiagnosticRuntime {
    let viewController = UIViewController()
    let summary = "Signal diagnostic runtime is ready."
    var signalDiagnosticAvailable: Bool
    var pauseSubmission = true
    var resumeSubmission = true
    private(set) var factoryCount = 0
    private(set) var startCount = 0
    private(set) var pauseRequestCount = 0
    private(set) var resumeRequestCount = 0
    private(set) var revokeCount = 0
    var onPauseRequest: (@MainActor () -> Void)?
    var onResumeRequest: (@MainActor () -> Void)?
    private var startCompletion: (@MainActor (Bool) -> Void)?

    init(available: Bool) {
        signalDiagnosticAvailable = available
    }

    func noteFactoryInvocation() { factoryCount += 1 }

    func start(completion: @escaping @MainActor (Bool) -> Void) {
        startCount += 1
        startCompletion = completion
    }

    func requestSignalDiagnosticPause() -> Bool {
        pauseRequestCount += 1
        onPauseRequest?()
        return pauseSubmission
    }

    func requestSignalDiagnosticResume() -> Bool {
        resumeRequestCount += 1
        onResumeRequest?()
        return resumeSubmission
    }

    func revoke() { revokeCount += 1 }

    func completeStart(_ started: Bool) { startCompletion?(started) }
}

@MainActor
private final class FakeGuestHandoffLease: NativeGuestHandoffLease {
    private(set) var isValid = true
    private(set) var endCount = 0
    var onEndDuringEnd: (@MainActor () -> Void)?
    private var onEnd: (@MainActor () -> Void)?
    private let expiresDuringInstall: Bool

    init(expiresDuringInstall: Bool = false) {
        self.expiresDuringInstall = expiresDuringInstall
    }

    func install(onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
        if expiresDuringInstall { expire() }
    }

    func expire() {
        guard isValid else { return }
        isValid = false
        onEnd?()
    }

    func end() {
        endCount += 1
        isValid = false
        onEndDuringEnd?()
    }
}

private actor SuspendedGuestChecker {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0

    func check(biometricEnabled: Bool) async throws {
        _ = biometricEnabled
        callCount += 1
        let ordinal = callCount
        startWaiters.removeValue(forKey: ordinal)?.resume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[ordinal] = continuation
        }
    }

    func waitForCall(_ ordinal: Int) async {
        if callCount >= ordinal { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters[ordinal] = continuation
        }
    }

    func succeed(_ ordinal: Int) -> Bool {
        guard let continuation = pending.removeValue(forKey: ordinal) else { return false }
        continuation.resume()
        return true
    }

    func fail(_ ordinal: Int) -> Bool {
        guard let continuation = pending.removeValue(forKey: ordinal) else { return false }
        continuation.resume(throwing: Failure.sensitive)
        return true
    }

    private enum Failure: Error {
        case sensitive
    }
}

private enum SyntheticFactoryFailure: Error {
    case failed
}
