import XCTest
@testable import CalcVault

@MainActor
final class SessionLifecycleCoordinatorTests: XCTestCase {
    func testStaleAuthenticationAttemptCannotCompleteAfterBackgrounding() {
        let coordinator = SessionLifecycleCoordinator()
        let attemptID = coordinator.beginAuthentication()
        coordinator.setAuthenticationPromptActive(false)

        coordinator.applicationWillResignActive()

        XCTAssertEqual(coordinator.state, .calculatorLocked)
        XCTAssertNil(coordinator.completeAuthentication(attemptID: attemptID))
    }

    func testOlderAuthenticationCallbackCannotCompleteNewerAttempt() {
        let coordinator = SessionLifecycleCoordinator()
        let staleAttemptID = coordinator.beginAuthentication()
        let currentAttemptID = coordinator.beginAuthentication()

        XCTAssertNil(coordinator.completeAuthentication(attemptID: staleAttemptID))
        let sessionID = coordinator.completeAuthentication(attemptID: currentAttemptID)

        XCTAssertNotNil(sessionID)
        XCTAssertTrue({
            guard let sessionID else { return false }
            return coordinator.isValidSession(
                sessionID: sessionID,
                generation: coordinator.sessionGeneration
            )
        }())
    }

    func testLockInvalidatesSessionAndGeneration() throws {
        let coordinator = SessionLifecycleCoordinator()
        let attemptID = coordinator.beginAuthentication()
        let sessionID = try XCTUnwrap(coordinator.completeAuthentication(attemptID: attemptID))
        let generation = coordinator.sessionGeneration

        XCTAssertTrue(coordinator.isValidSession(sessionID: sessionID, generation: generation))

        coordinator.lock()

        XCTAssertEqual(coordinator.state, .calculatorLocked)
        XCTAssertGreaterThan(coordinator.sessionGeneration, generation)
        XCTAssertFalse(coordinator.isValidSession(sessionID: sessionID, generation: generation))
    }

    func testPromptInactiveRaceRejectsCompletionWhileSceneIsInactive() {
        let coordinator = SessionLifecycleCoordinator()
        let attemptID = coordinator.beginAuthentication()

        // The active prompt keeps the attempt pending during an inactive
        // transition, but completion is still rejected until the scene is
        // foregrounded again.
        coordinator.applicationWillResignActive()

        XCTAssertEqual(coordinator.state, .authenticating(attemptID: attemptID))
        XCTAssertNil(coordinator.completeAuthentication(attemptID: attemptID))

        coordinator.applicationDidBecomeActive()
        let sessionID = coordinator.completeAuthentication(attemptID: attemptID)
        XCTAssertNotNil(sessionID)
    }

    func testBackgroundAlwaysInvalidatesPromptAttempt() {
        let coordinator = SessionLifecycleCoordinator()
        let attemptID = coordinator.beginAuthentication()

        coordinator.applicationDidEnterBackground()
        coordinator.applicationDidBecomeActive()

        XCTAssertEqual(coordinator.state, .calculatorLocked)
        XCTAssertNil(coordinator.completeAuthentication(attemptID: attemptID))
    }
}
