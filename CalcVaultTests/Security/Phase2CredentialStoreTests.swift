import Foundation
import LocalAuthentication
import XCTest
@testable import CalcVault

final class Phase2CredentialStoreTests: XCTestCase {
    func testEnrollmentCreatesSeparateNavigationAndAuthenticatedRootEnvelope() throws {
        let metadata = MemoryCredentialStore()
        let biometric = MemoryBiometricStore()
        let manager = makeManager(metadata: metadata, biometric: biometric)

        try manager.enroll(
            navigationSequence: "00123456",
            passphrase: "synthetic passphrase only",
            enableBiometrics: true
        )

        XCTAssertEqual(try manager.enrollmentState(), .configured(biometricEnabled: true))
        XCTAssertEqual(try manager.navigationSequence(), "00123456")
        XCTAssertNotNil(metadata.values[Phase2CredentialManager.navigationAccount])
        XCTAssertNotNil(metadata.values[Phase2CredentialManager.envelopeAccount])

        let envelope = try JSONDecoder().decode(
            Phase2PassphraseEnvelope.self,
            from: try XCTUnwrap(metadata.values[Phase2CredentialManager.envelopeAccount])
        )
        let passphraseRoot = try manager.unlock(passphrase: "synthetic passphrase only")
        let biometricRoot = try manager.unlockWithBiometrics(context: LAContext())
        XCTAssertEqual(try manager.vaultIdentity(), envelope.vaultID)
        XCTAssertEqual(passphraseRoot, biometricRoot)
        XCTAssertEqual(passphraseRoot.count, 32)
    }

    func testWrongPassphraseAndModifiedEnvelopeFailClosed() throws {
        let metadata = MemoryCredentialStore()
        let manager = makeManager(metadata: metadata)
        try manager.enroll(
            navigationSequence: "87654321",
            passphrase: "another synthetic phrase",
            enableBiometrics: false
        )

        XCTAssertThrowsError(try manager.unlock(passphrase: "wrong synthetic phrase")) { error in
            XCTAssertEqual(error as? Phase2CredentialError, .authenticationFailed)
        }

        let account = Phase2CredentialManager.envelopeAccount
        var envelope = try JSONDecoder().decode(
            Phase2PassphraseEnvelope.self,
            from: try XCTUnwrap(metadata.values[account])
        )
        var wrapped = envelope.wrappedRootKey
        wrapped[wrapped.startIndex] ^= 0x01
        envelope = Phase2PassphraseEnvelope(
            version: envelope.version,
            vaultID: envelope.vaultID,
            passphraseEncoding: envelope.passphraseEncoding,
            kdf: envelope.kdf,
            salt: envelope.salt,
            wrappedRootKey: wrapped,
            biometricEnabled: envelope.biometricEnabled
        )
        metadata.values[account] = try JSONEncoder().encode(envelope)

        XCTAssertThrowsError(try manager.unlock(passphrase: "another synthetic phrase")) { error in
            XCTAssertEqual(error as? Phase2CredentialError, .authenticationFailed)
        }
    }

    func testPartialEnrollmentFailureRollsBackOnlyNewItems() throws {
        let metadata = MemoryCredentialStore()
        metadata.failWriteAccount = Phase2CredentialManager.navigationAccount
        let manager = makeManager(metadata: metadata)

        XCTAssertThrowsError(
            try manager.enroll(
                navigationSequence: "12345678",
                passphrase: "disposable fixture phrase",
                enableBiometrics: false
            )
        )
        XCTAssertTrue(metadata.values.isEmpty)
        XCTAssertEqual(try manager.enrollmentState(), .unconfigured)
    }

    func testIncompleteConfigurationIsVisibleAndNeverReplaced() throws {
        let metadata = MemoryCredentialStore()
        metadata.values[Phase2CredentialManager.navigationAccount] = Data("12345678".utf8)
        let manager = makeManager(metadata: metadata)

        XCTAssertEqual(try manager.enrollmentState(), .inconsistent)
        XCTAssertThrowsError(
            try manager.enroll(
                navigationSequence: "87654321",
                passphrase: "disposable fixture phrase",
                enableBiometrics: false
            )
        ) { error in
            XCTAssertEqual(error as? Phase2CredentialError, .alreadyConfigured)
        }
        XCTAssertEqual(
            metadata.values[Phase2CredentialManager.navigationAccount],
            Data("12345678".utf8)
        )
    }

    func testNavigationReplacementChangesOnlyNavigationItemAndCanRestoreLongSequence() throws {
        let metadata = MemoryCredentialStore()
        let manager = makeManager(metadata: metadata)
        try manager.enroll(
            navigationSequence: "00123456",
            passphrase: "disposable fixture phrase",
            enableBiometrics: false
        )
        let envelopeBefore = metadata.values[Phase2CredentialManager.envelopeAccount]
        let rootBefore = try manager.unlock(passphrase: "disposable fixture phrase")

        try manager.replaceNavigationSequence("0")

        XCTAssertEqual(try manager.navigationSequence(), "0")
        XCTAssertEqual(try manager.enrollmentState(), .configured(biometricEnabled: false))
        XCTAssertEqual(metadata.values[Phase2CredentialManager.envelopeAccount], envelopeBefore)
        XCTAssertEqual(try manager.unlock(passphrase: "disposable fixture phrase"), rootBefore)

        try manager.replaceNavigationSequence("87654321")
        XCTAssertEqual(try manager.navigationSequence(), "87654321")
        XCTAssertEqual(metadata.values[Phase2CredentialManager.envelopeAccount], envelopeBefore)
    }

    func testFailedNavigationReplacementPreservesPreviousSequenceAndEnvelope() throws {
        let metadata = MemoryCredentialStore()
        let manager = makeManager(metadata: metadata)
        try manager.enroll(
            navigationSequence: "00123456",
            passphrase: "disposable fixture phrase",
            enableBiometrics: false
        )
        let previousValues = metadata.values
        metadata.failReplaceAccount = Phase2CredentialManager.navigationAccount

        XCTAssertThrowsError(try manager.replaceNavigationSequence("0"))
        XCTAssertEqual(metadata.values, previousValues)
        XCTAssertEqual(try manager.navigationSequence(), "00123456")
    }

    func testEnrollmentStillRejectsSingleDigitSequence() throws {
        let manager = makeManager(metadata: MemoryCredentialStore())
        XCTAssertThrowsError(
            try manager.enroll(
                navigationSequence: "0",
                passphrase: "disposable fixture phrase",
                enableBiometrics: false
            )
        ) { error in
            XCTAssertEqual(error as? Phase2CredentialError, .invalidNavigationSequence)
        }
    }

    func testInvalidReplacementDoesNotChangeStoredSequence() throws {
        let metadata = MemoryCredentialStore()
        let manager = makeManager(metadata: metadata)
        try manager.enroll(
            navigationSequence: "00123456",
            passphrase: "disposable fixture phrase",
            enableBiometrics: false
        )

        XCTAssertThrowsError(try manager.replaceNavigationSequence("")) { error in
            XCTAssertEqual(error as? Phase2CredentialError, .invalidReplacementNavigationSequence)
        }
        XCTAssertEqual(try manager.navigationSequence(), "00123456")
    }

    private func makeManager(
        metadata: MemoryCredentialStore,
        biometric: MemoryBiometricStore = MemoryBiometricStore()
    ) -> Phase2CredentialManager {
        Phase2CredentialManager(
            metadataStore: metadata,
            biometricStore: biometric,
            parameters: PassphraseKDFParameters(operationsLimit: 1, memoryLimit: 8 * 1_024)
        )
    }
}

private final class MemoryCredentialStore: Phase2CredentialPersisting {
    var values: [String: Data] = [:]
    var failWriteAccount: String?
    var failReplaceAccount: String?

    func read(account: String) throws -> Data? { values[account] }

    func write(_ data: Data, account: String) throws {
        if failWriteAccount == account {
            throw Phase2CredentialStoreError.unexpectedStatus(-1)
        }
        guard values[account] == nil else {
            throw Phase2CredentialStoreError.duplicateItem
        }
        values[account] = data
    }

    func replace(_ data: Data, account: String) throws {
        if failReplaceAccount == account {
            throw Phase2CredentialStoreError.unexpectedStatus(-1)
        }
        guard values[account] != nil else {
            throw Phase2CredentialStoreError.invalidItem
        }
        values[account] = data
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}

private final class MemoryBiometricStore: BiometricRootKeyPersisting {
    private var values: [String: Data] = [:]

    func write(_ data: Data, account: String) throws {
        guard values[account] == nil else { throw KeychainStoreError.duplicateItem }
        values[account] = data
    }

    func read(account: String, context: LAContext?) throws -> Data? {
        values[account]
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}
