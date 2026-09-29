import Foundation

/// Exact credential locations considered by the integration preflight.
/// This inventory is not a general Keychain enumeration or guest permit.
public enum NativeGuestCredentialInventory {
    public static let items: [KeychainMigrationItem] = [
        KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                              account: Phase2CredentialManager.navigationAccount,
                              protection: .whenUnlockedDeviceOnly),
        KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                              account: Phase2CredentialManager.envelopeAccount,
                              protection: .whenUnlockedDeviceOnly),
        KeychainMigrationItem(service: Phase2CredentialManager.metadataService,
                              account: VaultRepository.initializationAccount,
                              protection: .whenUnlockedDeviceOnly),
        // Check even if the current envelope disables biometrics: a historical
        // copy must not become invisible merely because a preference changed.
        KeychainMigrationItem(service: Phase2CredentialManager.biometricService,
                              account: Phase2CredentialManager.biometricRootAccount,
                              protection: .biometryCurrentSet)
    ]

    public static func checkLegacyAbsence(storage: HostOnlyKeychainStorage = HostOnlyKeychainStorage()) throws {
        try storage.assertNoLegacyCopies(items)
    }
}
