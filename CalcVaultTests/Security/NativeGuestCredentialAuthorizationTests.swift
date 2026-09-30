import Foundation
import LocalAuthentication
import XCTest
@testable import CalcVault

@MainActor
final class NativeGuestCredentialAuthorizationTests: XCTestCase {
    func testAuthenticationThenBoundaryCheckReuseOneContextWithoutDataReadsOrWrites() async throws {
        let groups = try makeGroups()
        let backend = AuthorizationTestBackend()
        var forwardedContexts: [LAContext?] = []
        let storage = HostOnlyKeychainStorage(
            groups: { groups },
            backend: { context in
                forwardedContexts.append(context)
                return backend
            }
        )
        let context = LAContext()
        var localizedReasons: [String] = []
        let authorization = NativeGuestBiometricAuthorization(
            context: context,
            storage: storage,
            biometricEvaluator: { suppliedContext, reason in
                XCTAssertTrue(suppliedContext === context)
                localizedReasons.append(reason)
            }
        )

        XCTAssertEqual(context.localizedFallbackTitle, "")
        do {
            try await authorization.check(biometricEnabled: false)
            XCTFail("The boundary check must require biometric authentication first")
        } catch {
            XCTAssertEqual(error as? NativeGuestCredentialAuthorizationError, .authenticationRequired)
        }

        try await authorization.authenticate()
        try await authorization.check(biometricEnabled: false)

        XCTAssertEqual(localizedReasons, ["Verify protected credentials before opening the isolated guest"])
        XCTAssertEqual(forwardedContexts.count, 1)
        XCTAssertTrue(forwardedContexts[0] === context)
        XCTAssertEqual(backend.validationCount, NativeGuestCredentialInventory.items.count)
        XCTAssertGreaterThan(backend.containsCount, 0)
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.mutationCount, 0)
        do {
            try await authorization.check(biometricEnabled: false)
            XCTFail("A checked authorization attempt must not be reused")
        } catch {
            XCTAssertEqual(error as? NativeGuestCredentialAuthorizationError, .attemptAlreadyUsed)
        }
    }

    func testInvalidationDuringBiometricPromptFailsClosed() async throws {
        let context = LAContext()
        let evaluationStarted = expectation(description: "Biometric evaluation started")
        var resumeEvaluation: CheckedContinuation<Void, Never>?
        let authorization = NativeGuestBiometricAuthorization(
            context: context,
            storage: HostOnlyKeychainStorage(),
            biometricEvaluator: { _, _ in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    resumeEvaluation = continuation
                    evaluationStarted.fulfill()
                }
            }
        )
        let authentication = Task { try await authorization.authenticate() }

        await fulfillment(of: [evaluationStarted], timeout: 2)
        authorization.invalidate()
        resumeEvaluation?.resume()

        do {
            try await authentication.value
            XCTFail("An invalidated authentication attempt must not succeed")
        } catch {
            XCTAssertEqual(error as? NativeGuestCredentialAuthorizationError, .invalidated)
        }
        do {
            try await authorization.authenticate()
            XCTFail("An invalidated context must not be reused")
        } catch {
            XCTAssertEqual(error as? NativeGuestCredentialAuthorizationError, .invalidated)
        }
    }

    func testCancellingPendingMetadataCheckInvalidatesTheAttempt() async throws {
        let groups = try makeGroups()
        let context = LAContext()
        let validationStarted = expectation(description: "Metadata validation started")
        let backend = AuthorizationTestBackend(
            validationStarted: validationStarted,
            validationGate: DispatchSemaphore(value: 0)
        )
        let storage = HostOnlyKeychainStorage(groups: { groups }, backend: { _ in backend })
        let authorization = NativeGuestBiometricAuthorization(
            context: context,
            storage: storage,
            biometricEvaluator: { _, _ in }
        )
        try await authorization.authenticate()

        let check = Task { try await authorization.check(biometricEnabled: true) }
        await fulfillment(of: [validationStarted], timeout: 2)
        check.cancel()
        backend.validationGate?.signal()

        do {
            try await check.value
            XCTFail("A cancelled metadata check must fail")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            try await authorization.check(biometricEnabled: true)
            XCTFail("A cancelled authorization attempt must not be reused")
        } catch {
            XCTAssertEqual(error as? NativeGuestCredentialAuthorizationError, .invalidated)
        }
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.mutationCount, 0)
    }

    private func makeGroups() throws -> KeychainAccessGroups {
        try KeychainAccessGroups(
            legacy: "ABCDE12345.com.example.calcvault.runtime",
            hostOnly: "ABCDE12345.com.example.calcvault.hostonly",
            additionalLegacyGroups: ["ABCDE12345.com.example.calcvault"]
        )
    }
}

private final class AuthorizationTestBackend: HostOnlyKeychainBackend {
    private let validationStarted: XCTestExpectation?
    let validationGate: DispatchSemaphore?
    private var shouldBlockValidation: Bool
    private(set) var containsCount = 0
    private(set) var validationCount = 0
    private(set) var readCount = 0
    private(set) var mutationCount = 0

    init(validationStarted: XCTestExpectation? = nil, validationGate: DispatchSemaphore? = nil) {
        self.validationStarted = validationStarted
        self.validationGate = validationGate
        self.shouldBlockValidation = validationGate != nil
    }

    func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? {
        readCount += 1
        return nil
    }

    func insert(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        mutationCount += 1
    }

    func remove(_ item: KeychainMigrationItem, accessGroup: String) throws {
        mutationCount += 1
    }

    func contains(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        containsCount += 1
        return false
    }

    func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        validationCount += 1
        if shouldBlockValidation, let validationGate {
            shouldBlockValidation = false
            validationStarted?.fulfill()
            validationGate.wait()
        }
        return true
    }

    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        mutationCount += 1
    }
}
