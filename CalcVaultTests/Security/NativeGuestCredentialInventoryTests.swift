import Foundation
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
                    XCTAssertEqual(error as? HostOnlyKeychainStorageError, .invalidItem)
                }
            } else {
                XCTAssertNoThrow(try NativeGuestCredentialInventory.checkForLaunch(
                    biometricEnabled: false,
                    storage: storage
                ))
            }

            XCTAssertTrue(backend.validationCalls.contains { $0.item == items[3] })
            XCTAssertTrue(backend.containsCalls.contains { $0.item == items[3] })
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
        return present.contains(InventoryScopedCredential(item: item, group: accessGroup))
    }

    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        mutationCount += 1
    }
}
