import Foundation
import UIKit
import XCTest
@testable import CalcVault

@MainActor
final class NativeGuestBiometricLaunchTests: XCTestCase {
    func testBiometricsRequireFullRecheckAndInvalidateBeforeFactory() async throws {
        let (lifecycle, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertEqual(model.state, .checking)
        authorization.completeAuthentication()
        await authorization.waitForCheck()
        XCTAssertEqual(runtime.factoryCount, 0)
        authorization.completeCheck()
        await task.value
        XCTAssertEqual(authorization.invalidateCount, 1)
        XCTAssertTrue(runtime.contextInvalidatedAtFactory)
        XCTAssertEqual(model.state, .presenting)
        lifecycle.lock()
        XCTAssertFalse(model.showingGuest)
    }

    func testInactiveAuthenticationCompletionWaitsForForeground() async throws {
        let (lifecycle, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        lifecycle.applicationWillResignActive()
        authorization.completeAuthentication()
        await Task.yield()
        XCTAssertEqual(authorization.checkCount, 0)
        XCTAssertEqual(runtime.factoryCount, 0)
        lifecycle.applicationDidBecomeActive()
        await authorization.waitForCheck()
        authorization.completeCheck()
        await task.value
        XCTAssertEqual(model.state, .presenting)
    }

    func testBackgroundInvalidatesContextAndRejectsLateSuccess() async throws {
        let (lifecycle, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        lifecycle.applicationWillResignActive()
        lifecycle.applicationDidEnterBackground()
        XCTAssertEqual(authorization.invalidateCount, 1)
        lifecycle.applicationDidBecomeActive()
        _ = lifecycle.completeAuthentication(attemptID: lifecycle.beginAuthentication())
        authorization.completeAuthentication()
        await task.value
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertEqual(authorization.checkCount, 0)
        XCTAssertFalse(model.showingGuest)
    }

    func testExplicitLockDuringRecheckPreventsFactory() async throws {
        let (lifecycle, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        authorization.completeAuthentication()
        await authorization.waitForCheck()
        lifecycle.lock()
        XCTAssertEqual(authorization.invalidateCount, 1)
        authorization.completeCheck()
        await task.value
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertFalse(model.showingGuest)
    }

    func testCancelDoesNotLaunchOrExposeRawAuthenticationError() async throws {
        let (_, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        authorization.completeAuthentication(error: NSError(domain: "secret-error", code: 77))
        await task.value
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertEqual(authorization.checkCount, 0)
        XCTAssertEqual(authorization.invalidateCount, 1)
        XCTAssertEqual(model.state, .blocked)
        XCTAssertTrue(model.summary.contains("stage=credential-authentication; reason=cancelled-or-unavailable"))
        XCTAssertFalse(model.summary.contains("secret-error"))
    }

    func testRecheckFailureRemainsBlockedWithoutAuthenticationLoop() async throws {
        let (_, model, authorization, runtime) = try fixture()
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await authorization.waitForAuthentication()
        authorization.completeAuthentication()
        await authorization.waitForCheck()
        authorization.completeCheck(error: try boundaryFailure())
        await task.value
        XCTAssertEqual(runtime.factoryCount, 0)
        XCTAssertEqual(authorization.authenticateCount, 1)
        XCTAssertEqual(authorization.invalidateCount, 1)
        XCTAssertEqual(model.state, .blocked)
        XCTAssertTrue(model.summary.contains("required-protection.item-2.status:-25308"))
    }

    func testUnrelatedFailureNeverRequestsBiometrics() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = lifecycle.completeAuthentication(attemptID: lifecycle.beginAuthentication())
        let error = try boundaryFailure(status: -34018)
        var authorizationCount = 0
        let model = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in throw error },
            runtimeFactory: { XCTFail("Factory must not run"); return BiometricTestRuntime() },
            authorizationFactory: { authorizationCount += 1; return SuspendedAuthorization() })
        let task = try XCTUnwrap(model.start(biometricEnabled: true))
        await task.value
        XCTAssertEqual(authorizationCount, 0)
        XCTAssertEqual(model.state, .blocked)
    }

    func testStaleAuthenticationCannotCancelNewSessionPrompt() async throws {
        let lifecycle = SessionLifecycleCoordinator()
        _ = lifecycle.completeAuthentication(attemptID: lifecycle.beginAuthentication())
        let error = try boundaryFailure()
        let old = SuspendedAuthorization()
        let current = SuspendedAuthorization()
        let runtime = BiometricTestRuntime()
        var count = 0
        let model = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in throw error },
            runtimeFactory: { runtime.factoryCount += 1; return runtime },
            authorizationFactory: { count += 1; return count == 1 ? old : current })
        let staleTask = try XCTUnwrap(model.start(biometricEnabled: true))
        await old.waitForAuthentication()
        lifecycle.lock()
        _ = lifecycle.completeAuthentication(attemptID: lifecycle.beginAuthentication())
        let currentTask = try XCTUnwrap(model.start(biometricEnabled: true))
        await current.waitForAuthentication()
        old.completeAuthentication()
        await staleTask.value
        XCTAssertEqual(current.invalidateCount, 0)
        XCTAssertEqual(model.state, .checking)
        lifecycle.applicationWillResignActive()
        current.completeAuthentication()
        lifecycle.applicationDidBecomeActive()
        await current.waitForCheck()
        current.completeCheck()
        await currentTask.value
        XCTAssertEqual(runtime.factoryCount, 1)
        XCTAssertEqual(current.invalidateCount, 1)
        XCTAssertEqual(model.state, .presenting)
    }

    private func fixture() throws -> (SessionLifecycleCoordinator, NativeGuestCoordinator, SuspendedAuthorization, BiometricTestRuntime) {
        let lifecycle = SessionLifecycleCoordinator()
        _ = lifecycle.completeAuthentication(attemptID: lifecycle.beginAuthentication())
        let error = try boundaryFailure()
        let authorization = SuspendedAuthorization()
        let runtime = BiometricTestRuntime()
        let model = NativeGuestCoordinator(lifecycle: lifecycle, check: { _ in throw error },
            runtimeFactory: {
                runtime.factoryCount += 1
                runtime.contextInvalidatedAtFactory = authorization.invalidateCount > 0
                return runtime
            }, authorizationFactory: { authorization })
        return (lifecycle, model, authorization, runtime)
    }

    private func boundaryFailure(status: Int32 = -25308) throws -> NativeGuestCredentialBoundaryFailure {
        let groups = try KeychainAccessGroups(legacy: "TEST.legacy", hostOnly: "TEST.hostonly")
        let storage = HostOnlyKeychainStorage(groups: { groups }, backend: { _ in BiometricStatusBackend(status: status) })
        do {
            try NativeGuestCredentialInventory.checkForLaunch(biometricEnabled: true, storage: storage)
            throw NSError(domain: "Expected synthetic boundary failure", code: 1)
        } catch let error as NativeGuestCredentialBoundaryFailure { return error }
    }
}

@MainActor
private final class SuspendedAuthorization: NativeGuestCredentialAuthorization {
    var authenticateCount = 0
    var checkCount = 0
    var invalidateCount = 0
    private var authentication: CheckedContinuation<Void, Error>?
    private var checkContinuation: CheckedContinuation<Void, Error>?
    private var authWaiter: CheckedContinuation<Void, Never>?
    private var checkWaiter: CheckedContinuation<Void, Never>?
    func authenticate() async throws {
        authenticateCount += 1
        try await withCheckedThrowingContinuation { continuation in
            authentication = continuation
            authWaiter?.resume(); authWaiter = nil
        }
    }
    func check(biometricEnabled: Bool) async throws {
        checkCount += 1
        try await withCheckedThrowingContinuation { continuation in
            checkContinuation = continuation
            checkWaiter?.resume(); checkWaiter = nil
        }
    }
    func invalidate() { invalidateCount += 1 }
    func waitForAuthentication() async {
        if authentication != nil { return }
        await withCheckedContinuation { authWaiter = $0 }
    }
    func waitForCheck() async {
        if checkContinuation != nil { return }
        await withCheckedContinuation { checkWaiter = $0 }
    }
    func completeAuthentication(error: Error? = nil) {
        let pending = authentication; authentication = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
    func completeCheck(error: Error? = nil) {
        let pending = checkContinuation; checkContinuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

@MainActor
private final class BiometricTestRuntime: NativeGuestRuntime {
    let viewController = UIViewController()
    let summary = "Synthetic runtime"
    var factoryCount = 0
    var contextInvalidatedAtFactory = false
    func start(completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func revoke() {}
}

private final class BiometricStatusBackend: HostOnlyKeychainBackend {
    let status: Int32
    init(status: Int32) { self.status = status }
    func contains(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool { false }
    func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        if item.protection == .biometryCurrentSet { throw HostOnlyKeychainStorageError.unexpectedStatus(status) }
        return true
    }
    func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? { XCTFail("No secret reads"); return nil }
    func insert(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws { XCTFail("No writes") }
    func remove(_ item: KeychainMigrationItem, accessGroup: String) throws { XCTFail("No removals") }
    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws { XCTFail("No replacements") }
}
