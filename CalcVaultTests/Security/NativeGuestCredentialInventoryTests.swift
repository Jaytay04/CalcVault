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
}
