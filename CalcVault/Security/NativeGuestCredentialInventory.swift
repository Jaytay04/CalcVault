import Foundation

/// Exact credential locations considered by the integration preflight.
/// This inventory is not a general Keychain enumeration or guest permit.
public enum NativeGuestCredentialInventory {
    private static let navigationItem = KeychainMigrationItem(
        service: Phase2CredentialManager.metadataService,
        account: Phase2CredentialManager.navigationAccount,
        protection: .whenUnlockedDeviceOnly
    )
    private static let envelopeItem = KeychainMigrationItem(
        service: Phase2CredentialManager.metadataService,
        account: Phase2CredentialManager.envelopeAccount,
        protection: .whenUnlockedDeviceOnly
    )
    private static let initializationItem = KeychainMigrationItem(
        service: Phase2CredentialManager.metadataService,
        account: VaultRepository.initializationAccount,
        protection: .whenUnlockedDeviceOnly
    )
    private static let biometricRootItem = KeychainMigrationItem(
        service: Phase2CredentialManager.biometricService,
        account: Phase2CredentialManager.biometricRootAccount,
        protection: .biometryCurrentSet
    )

    public static let items: [KeychainMigrationItem] = [
        navigationItem,
        envelopeItem,
        initializationItem,
        // Check even if the current envelope disables biometrics: a historical
        // copy must not become invisible merely because a preference changed.
        biometricRootItem
    ]

    public static func checkForLaunch(
        biometricEnabled: Bool,
        storage: HostOnlyKeychainStorage = HostOnlyKeychainStorage()
    ) throws {
        var required = [navigationItem, envelopeItem]
        var optional = [initializationItem]
        if biometricEnabled {
            required.append(biometricRootItem)
        } else {
            optional.append(biometricRootItem)
        }
        try storage.assertGuestCredentialBoundary(
            required: required,
            optional: optional,
            diagnosticErrors: true
        )
    }

    public static func checkLegacyAbsence(storage: HostOnlyKeychainStorage = HostOnlyKeychainStorage()) throws {
        try storage.assertNoLegacyCopies(items)
    }
}
