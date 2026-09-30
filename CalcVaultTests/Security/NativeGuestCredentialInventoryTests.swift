import Foundation
import LocalAuthentication
import XCTest
@testable import CalcVault

final class NativeGuestCredentialInventoryTests: XCTestCase {
    func testInventoryIncludesEveryKnownCredentialWithExactIdentity() {
        let items = NativeGuestCredentialInventory.items
        XCTAssertEqual(items, [
            KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                                  account: Phase2CredentialManager.navigationAccount,
                                  protection: .whenUnlockedDeviceOnly),
            KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                                  account: Phase2CredentialManager.envelopeAccount,
                                  protection: .whenUnlockedDeviceOnly),
            KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                                  account: VaultRepository.initializationAccount,
                                  protection: .whenUnlockedDeviceOnly),
            KeychainMigrationItem(service: Phase2CredentialManager.biometricService,
                                  account: Phase2CredentialManager.biometricRootAccount,
                                  protection: .biometryCurrentSet)
        ])
        XCTAssertEqual(Set(items).count, 4)
    }

    func testLaunchCheckUsesExactInventoryForBothBiometricPreferences() throws {
        let items = NativeGuestCredentialInventory.items
        let navigation = items[0]
        let envelope = items[1]
        let initialization = items[2]
        let biometricRoot = items[3]
        let groups = try makeGroups()

        for biometricEnabled in [false, true] {
            let backend = GuestInventoryBackend()
            backend.present.insert(InventoryScopedCredential(item: navigation, group: groups.hostOnly))
            backend.present.insert(InventoryScopedCredential(item: envelope, group: groups.hostOnly))
            backend.present.insert(InventoryScopedCredential(item: initialization, group: groups.hostOnly))
            backend.present.insert(InventoryScopedCredential(item: biometricRoot, group: groups.hostOnly))
            let storage = HostOnlyKeychainStorage(
                groups: { groups },
                backend: { _ in backend }
            )

            XCTAssertNoThrow(try NativeGuestCredentialInventory.checkForLaunch(
                biometricEnabled: biometricEnabled,
                storage: storage
            ))

            let expectedOrder = biometricEnabled
                ? [navigation, envelope, biometricRoot, initialization]
                : [navigation, envelope, initialization, biometricRoot]
            XCTAssertEqual(backend.validationCalls.map(\.item), expectedOrder)
            XCTAssertEqual(
                backend.validationCalls.map(\.group),
                Array(repeating: groups.hostOnly, count: expectedOrder.count)
            )
            XCTAssertEqual(
                backend.containsCalls.map { "\($0.item.service)|\($0.item.account)|\($0.group)" },
                expectedOrder.flatMap { item in
                    groups.legacyGroups.map { "\(item.service)|\(item.account)|\($0)" }
                }
            )
            XCTAssertEqual(backend.readCount, 0)
            XCTAssertEqual(backend.mutationCount, 0)
        }
    }

    func testLaunchCheckForwardsAnExplicitContextWhileDefaultScanRemainsNil() throws {
        let groups = try makeGroups()
        let backend = GuestInventoryBackend()
        for item in NativeGuestCredentialInventory.items {
            backend.present.insert(InventoryScopedCredential(item: item, group: groups.hostOnly))
        }
        var contexts: [LAContext?] = []
        let storage = HostOnlyKeychainStorage(
            groups: { groups },
            backend: { context in
                contexts.append(context)
                return backend
            }
        )
        let context = LAContext()

        XCTAssertNoThrow(try NativeGuestCredentialInventory.checkForLaunch(
            biometricEnabled: true,
            storage: storage
        ))
        XCTAssertNoThrow(try NativeGuestCredentialInventory.checkForLaunch(
            biometricEnabled: true,
            storage: storage,
            context: context
        ))

        XCTAssertEqual(contexts.count, 2)
        XCTAssertNil(contexts[0])
        XCTAssertTrue(contexts[1] === context)
        XCTAssertEqual(backend.readCount, 0)
        XCTAssertEqual(backend.mutationCount, 0)
    }

    func testBiometricRootIsOptionalWhenDisabledAndRequiredWhenEnabled() throws {
        let items = NativeGuestCredentialInventory.items
        let groups = try makeGroups()

        for biometricEnabled in [false, true] {
            let backend = GuestInventoryBackend()
            for item in items.prefix(2) {
                backend.present.insert(InventoryScopedCredential(item: item, group: groups.hostOnly))
            }
            let storage = HostOnlyKeychainStorage(
                groups: { groups },
                backend: { _ in backend }
            )

            if biometricEnabled {
                XCTAssertThrowsError(try NativeGuestCredentialInventory.checkForLaunch(
                    biometricEnabled: true,
                    storage: storage
                )) { error in
                    XCTAssertEqual(
                        (error as? NativeGuestCredentialBoundaryFailure)?.diagnosticCode,
                        "native-guest-boundary.required-protection.item-2.invalid-item"
                    )
                }
            } else {
                XCTAssertNoThrow(try NativeGuestCredentialInventory.checkForLaunch(
                    biometricEnabled: false,
                    storage: storage
                ))
            }

            XCTAssertTrue(backend.validationCalls.contains { $0.item == items[3] })
            XCTAssertTrue(backend.containsCalls.contains { $0.item == items[3] })
            XCTAssertEqual(backend.readCount, 0)
            XCTAssertEqual(backend.mutationCount, 0)
        }
    }

    func testBiometricFallbackEligibilityRequiresTheExactProtectedItemAndStatus() throws {
        let items = NativeGuestCredentialInventory.items
        let groups = try makeGroups()

        let requiredFailure = try XCTUnwrap(launchFailure(
            biometricEnabled: true,
            failingItem: items[3],
            status: -25308,
            groups: groups
        ))
        XCTAssertEqual(requiredFailure.diagnosticCode,
                       "native-guest-boundary.required-protection.item-2.status:-25308")
        XCTAssertTrue(requiredFailure.requiresBiometricAuthentication(biometricEnabled: true))
        XCTAssertFalse(requiredFailure.requiresBiometricAuthentication(biometricEnabled: false))

        let optionalFailure = try XCTUnwrap(launchFailure(
            biometricEnabled: false,
            failingItem: items[3],
            status: -25308,
            groups: groups
        ))
        XCTAssertEqual(optionalFailure.diagnosticCode,
                       "native-guest-boundary.optional-protection.item-1.status:-25308")
        XCTAssertTrue(optionalFailure.requiresBiometricAuthentication(biometricEnabled: false))
        XCTAssertFalse(optionalFailure.requiresBiometricAuthentication(biometricEnabled: true))

        let unrelatedRequiredItemFailure = try XCTUnwrap(launchFailure(
            biometricEnabled: true,
            failingItem: items[1],
            status: -25308,
            groups: groups
        ))
        XCTAssertFalse(unrelatedRequiredItemFailure.requiresBiometricAuthentication(biometricEnabled: true))

        let unrelatedStatusFailure = try XCTUnwrap(launchFailure(
            biometricEnabled: true,
            failingItem: items[3],
            status: -50,
            groups: groups
        ))
        XCTAssertFalse(unrelatedStatusFailure.requiresBiometricAuthentication(biometricEnabled: true))
    }

    private func launchFailure(
        biometricEnabled: Bool,
        failingItem: KeychainMigrationItem,
        status: Int32,
        groups: KeychainAccessGroups
    ) -> NativeGuestCredentialBoundaryFailure? {
        let backend = GuestInventoryBackend()
        for item in NativeGuestCredentialInventory.items {
            backend.present.insert(InventoryScopedCredential(item: item, group: groups.hostOnly))
        }
        backend.failValidationFor = failingItem
        backend.validationFailureStatus = status
        let storage = HostOnlyKeychainStorage(groups: { groups }, backend: { _ in backend })

        do {
            try NativeGuestCredentialInventory.checkForLaunch(biometricEnabled: biometricEnabled, storage: storage)
            XCTFail("Expected the guest boundary check to fail")
            return nil
        } catch let failure as NativeGuestCredentialBoundaryFailure {
            return failure
        } catch {
            XCTFail("Expected a sanitized guest boundary failure")
            return nil
        }
    }

    private func makeGroups() throws -> KeychainAccessGroups {
        try KeychainAccessGroups(
            legacy: "ABCDE12345.com.example.calcvault.runtime",
            hostOnly: "ABCDE12345.com.example.calcvault.hostonly",
            additionalLegacyGroups: ["ABCDE12345.com.example.calcvault"]
        )
    }
}

private struct InventoryScopedCredential: Hashable {
    let item: KeychainMigrationItem
    let group: String
}

private struct InventoryCall {
    let item: KeychainMigrationItem
    let group: String
}

private final class GuestInventoryBackend: HostOnlyKeychainBackend {
    var present: Set<InventoryScopedCredential> = []
    var containsCalls: [InventoryCall] = []
    var validationCalls: [InventoryCall] = []
    var readCount = 0
    var mutationCount = 0
    var failValidationFor: KeychainMigrationItem?
    var validationFailureStatus: Int32 = -1

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
        containsCalls.append(InventoryCall(item: item, group: accessGroup))
        return false
    }

    func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        validationCalls.append(InventoryCall(item: item, group: accessGroup))
        if item == failValidationFor {
            throw HostOnlyKeychainStorageError.unexpectedStatus(validationFailureStatus)
        }
        return present.contains(InventoryScopedCredential(item: item, group: accessGroup))
    }

    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        mutationCount += 1
    }
}
