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

    func testPrivatePromptSuspendsAuthorityUntilForegroundCompletion() async throws {
        let coordinator = SessionLifecycleCoordinator()
        let session = try XCTUnwrap(coordinator.completeAuthentication(attemptID: coordinator.beginAuthentication()))
        let generation = coordinator.sessionGeneration
        let token = try XCTUnwrap(coordinator.beginPrivateAuthenticationPrompt(sessionID: session, generation: generation))
        XCTAssertFalse(coordinator.isValidSession(sessionID: session, generation: generation))
        coordinator.applicationWillResignActive()
        XCTAssertEqual(coordinator.state, .privateUnlocked(sessionID: session))
        let completion = Task { await coordinator.completePrivateAuthenticationPrompt(token) }
        await Task.yield()
        XCTAssertFalse(coordinator.isValidSession(sessionID: session, generation: generation))
        coordinator.applicationDidBecomeActive()
        let accepted = await completion.value
        XCTAssertTrue(accepted)
        XCTAssertTrue(coordinator.isValidSession(sessionID: session, generation: generation))
        coordinator.applicationWillResignActive()
        XCTAssertEqual(coordinator.state, .calculatorLocked)
    }

    func testPrivatePromptBackgroundRevokesWaitingCompletion() async throws {
        let coordinator = SessionLifecycleCoordinator()
        let session = try XCTUnwrap(coordinator.completeAuthentication(attemptID: coordinator.beginAuthentication()))
        let token = try XCTUnwrap(coordinator.beginPrivateAuthenticationPrompt(
            sessionID: session, generation: coordinator.sessionGeneration
        ))
        coordinator.applicationWillResignActive()
        let completion = Task { await coordinator.completePrivateAuthenticationPrompt(token) }
        await Task.yield()
        coordinator.applicationDidEnterBackground()
        coordinator.applicationDidBecomeActive()
        let accepted = await completion.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.state, .calculatorLocked)
    }

    func testPrivatePromptRejectsWrongSessionAndStaleCancellation() async throws {
        let coordinator = SessionLifecycleCoordinator()
        let session = try XCTUnwrap(coordinator.completeAuthentication(attemptID: coordinator.beginAuthentication()))
        XCTAssertNil(coordinator.beginPrivateAuthenticationPrompt(sessionID: UUID(), generation: coordinator.sessionGeneration))
        let old = try XCTUnwrap(coordinator.beginPrivateAuthenticationPrompt(sessionID: session, generation: coordinator.sessionGeneration))
        coordinator.cancelPrivateAuthenticationPrompt(old)
        let current = try XCTUnwrap(coordinator.beginPrivateAuthenticationPrompt(sessionID: session, generation: coordinator.sessionGeneration))
        coordinator.cancelPrivateAuthenticationPrompt(old)
        let staleAccepted = await coordinator.completePrivateAuthenticationPrompt(old)
        XCTAssertFalse(staleAccepted)
        coordinator.applicationWillResignActive()
        XCTAssertEqual(coordinator.state, .privateUnlocked(sessionID: session))
        coordinator.cancelPrivateAuthenticationPrompt(current)
        XCTAssertEqual(coordinator.state, .calculatorLocked)
    }

    func testPrivatePromptDeadlineRevokesSessionAndForegroundWait() async throws {
        let coordinator = SessionLifecycleCoordinator(privatePromptTimeoutNanoseconds: 1_000_000)
        let app = AppCoordinator(lifecycle: coordinator, credentials: Phase2CredentialManager(
            metadataStore: EmptyLifecycleCredentialStore()
        ))
        let session = try XCTUnwrap(coordinator.completeAuthentication(attemptID: coordinator.beginAuthentication()))
        let token = try XCTUnwrap(coordinator.beginPrivateAuthenticationPrompt(sessionID: session, generation: coordinator.sessionGeneration))
        coordinator.applicationWillResignActive()
        let accepted = await coordinator.completePrivateAuthenticationPrompt(token)
        XCTAssertFalse(accepted)
        XCTAssertEqual(coordinator.state, .calculatorLocked)
        XCTAssertEqual(app.lifecycleState, .calculatorLocked)
        XCTAssertEqual(app.vaultStorageState, .locked)
        coordinator.applicationDidBecomeActive()
        XCTAssertEqual(coordinator.state, .calculatorLocked)
    }
}

private final class EmptyLifecycleCredentialStore: Phase2CredentialPersisting {
    func read(account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String) throws { XCTFail("No credential writes") }
    func replace(_ data: Data, account: String) throws { XCTFail("No credential replacements") }
    func delete(account: String) throws { XCTFail("No credential removals") }
}
