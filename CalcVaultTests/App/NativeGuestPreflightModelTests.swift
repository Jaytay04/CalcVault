import XCTest
@testable import CalcVault

@MainActor
final class NativeGuestPreflightModelTests: XCTestCase {
    func testCheckIsRejectedWhileLockedOrAuthenticating() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        let checker = SuspendedPreflightChecker()
        let model = NativeGuestPreflightModel(lifecycle: lifecycle) {
            try await checker.check()
        }

        XCTAssertNil(model.check())
        XCTAssertEqual(model.state, .blocked)

        lifecycle.beginAuthentication()
        XCTAssertEqual(model.state, .notChecked)
        XCTAssertNil(model.check())
        XCTAssertEqual(model.state, .blocked)

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testActiveSessionCanCompleteSuccessfully() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let task = try XCTUnwrap(model.check())
        XCTAssertEqual(model.state, .checking)
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(model.state, .noLegacyCopiesObserved)
    }

    func testActiveSessionFailureOnlyProducesBlockedState() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let task = try XCTUnwrap(model.check())
        await checker.waitForCall(1)
        let resolved = await checker.fail(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(model.state, .blocked)
    }

    func testDuplicateInFlightCheckIsRejected() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let firstTask = try XCTUnwrap(model.check())
        XCTAssertNil(model.check())
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await firstTask.value

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(model.state, .noLegacyCopiesObserved)
    }

    func testExplicitLockInvalidatesInFlightCheck() async throws {
        try await assertLifecycleTransitionInvalidatesCheck { $0.lock() }
    }

    func testBackgroundInvalidatesInFlightCheck() async throws {
        try await assertLifecycleTransitionInvalidatesCheck { $0.applicationDidEnterBackground() }
    }

    func testInactiveTransitionInvalidatesInFlightCheck() async throws {
        try await assertLifecycleTransitionInvalidatesCheck { $0.applicationWillResignActive() }
    }

    func testLifecycleTransitionClearsCompletedObservation() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let task = try XCTUnwrap(model.check())
        await checker.waitForCall(1)
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value
        XCTAssertEqual(model.state, .noLegacyCopiesObserved)

        lifecycle.beginAuthentication()
        XCTAssertEqual(model.state, .notChecked)
    }

    func testExplicitTaskCancellationCannotReportSuccess() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let task = try XCTUnwrap(model.check())
        await checker.waitForCall(1)
        task.cancel()
        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value

        XCTAssertEqual(model.state, .notChecked)
    }

    func testLateSuccessCannotChangeStatusOfFreshSessionRequest() async throws {
        try await assertLateCompletionCannotChangeFreshRequest(failOldRequest: false)
    }

    func testLateFailureCannotChangeStatusOfFreshSessionRequest() async throws {
        try await assertLateCompletionCannotChangeFreshRequest(failOldRequest: true)
    }

    func testCompletedObservationCanBeRescanned() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let firstTask = try XCTUnwrap(model.check())
        await checker.waitForCall(1)
        let firstResolved = await checker.succeed(1)
        XCTAssertTrue(firstResolved)
        await firstTask.value
        XCTAssertEqual(model.state, .noLegacyCopiesObserved)

        let secondTask = try XCTUnwrap(model.check())
        XCTAssertEqual(model.state, .checking)
        await checker.waitForCall(2)
        let secondResolved = await checker.succeed(2)
        XCTAssertTrue(secondResolved)
        await secondTask.value

        let callCount = await checker.callCount
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(model.state, .noLegacyCopiesObserved)
    }

    private func assertLifecycleTransitionInvalidatesCheck(
        transition: (SessionLifecycleCoordinator) -> Void
    ) async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)
        let task = try XCTUnwrap(model.check())
        await checker.waitForCall(1)

        transition(lifecycle)
        XCTAssertEqual(model.state, .notChecked)

        let resolved = await checker.succeed(1)
        XCTAssertTrue(resolved)
        await task.value
        XCTAssertEqual(model.state, .notChecked)
    }

    private func assertLateCompletionCannotChangeFreshRequest(
        failOldRequest: Bool
    ) async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = try unlock(lifecycle)
        let checker = SuspendedPreflightChecker()
        let model = makeModel(lifecycle: lifecycle, checker: checker)

        let oldTask = try XCTUnwrap(model.check())
        await checker.waitForCall(1)
        lifecycle.lock()
        XCTAssertEqual(model.state, .notChecked)

        _ = try unlock(lifecycle)
        let currentTask = try XCTUnwrap(model.check())
        await checker.waitForCall(2)

        let oldResolved: Bool
        if failOldRequest {
            oldResolved = await checker.fail(1)
        } else {
            oldResolved = await checker.succeed(1)
        }
        XCTAssertTrue(oldResolved)
        await oldTask.value
        XCTAssertEqual(model.state, .checking)

        let currentResolved = await checker.succeed(2)
        XCTAssertTrue(currentResolved)
        await currentTask.value
        XCTAssertEqual(model.state, .noLegacyCopiesObserved)
    }

    private func makeModel(
        lifecycle: SessionLifecycleCoordinator,
        checker: SuspendedPreflightChecker
    ) -> NativeGuestPreflightModel {
        NativeGuestPreflightModel(lifecycle: lifecycle) {
            try await checker.check()
        }
    }

    private func unlock(_ lifecycle: SessionLifecycleCoordinator) throws -> UUID {
        let attemptID = lifecycle.beginAuthentication()
        return try XCTUnwrap(lifecycle.completeAuthentication(attemptID: attemptID))
    }
}

private actor SuspendedPreflightChecker {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var startWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var callCount = 0

    func check() async throws {
        callCount += 1
        let ordinal = callCount
        startWaiters.removeValue(forKey: ordinal)?.resume()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[ordinal] = continuation
        }
    }

    func waitForCall(_ ordinal: Int) async {
        guard callCount < ordinal else { return }
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
