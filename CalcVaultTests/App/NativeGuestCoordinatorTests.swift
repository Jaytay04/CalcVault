import UIKit
import XCTest
@testable import CalcVault

@MainActor
final class NativeGuestCoordinatorTests: XCTestCase {
    func testLockedAndAuthenticatingSessionsCannotStartCheck() async {
        let lifecycle = SessionLifecycleCoordinator()
        let checker = SuspendedGuestChecker()
        let coordinator = makeCoordinator(lifecycle: lifecycle, checker: checker, runtime: FakeGuestRuntime())

        XCTAssertNil(coordinator.start(biometricEnabled: true))
        XCTAssertEqual(coordinator.state, .blocked)

        lifecycle.beginAuthentication()
        XCTAssertEqual(coordinator.state, .idle)
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

        let task = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        XCTAssertEqual(coordinator.state, .checking)
        await checker.waitForCall(1)
        XCTAssertEqual(runtime.factoryCount, 0)

        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(coordinator.state, .presenting)
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
        XCTAssertNotNil(coordinator.viewController)

        lifecycle.lock()

        XCTAssertEqual(coordinator.state, .ended)
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

        let retryTask = try XCTUnwrap(coordinator.start(biometricEnabled: true))
        await checker.waitForCall(2)
        let retryResolved = await checker.succeed(2)
        XCTAssertTrue(retryResolved)
        await retryTask.value
        XCTAssertEqual(coordinator.state, .presenting)
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
