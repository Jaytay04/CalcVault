import Foundation

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

#if canImport(Security)
import Security
#endif

public enum KeychainMigrationProtection: Equatable, Hashable, Sendable {
    case whenUnlockedDeviceOnly
    case biometryCurrentSet
}

public struct KeychainMigrationItem: Equatable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let protection: KeychainMigrationProtection

    public init(service: String, account: String, protection: KeychainMigrationProtection) {
        self.service = service
        self.account = account
        self.protection = protection
    }
}

public protocol KeychainMigrationStore {
    func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data?
    func insert(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws
    func remove(_ item: KeychainMigrationItem, accessGroup: String) throws
}

public enum KeychainMigrationOutcome: Equatable, Sendable {
    case absent
    case alreadyMoved
    case moved
}

public enum KeychainGroupMigrationError: Error, Equatable, LocalizedError {
    case invalidGroups
    case conflictingItems
    case destinationVerificationFailed
    case sourceChanged
    case sourceRemovalNotConfirmed
    case unexpectedStatus(Int32)
    case invalidItem
    case accessControlCreationFailed

    public var errorDescription: String? {
        if case .unexpectedStatus(let status) = self {
            return "Credential migration could not complete (Keychain status \(status)). No replacement configuration was created."
        }
        return "Credential migration could not be verified. Existing credential copies were not overwritten; no replacement configuration was created."
    }
}

/// Copies one exact generic-password item between explicit Keychain groups,
/// verifies the copy, and then removes only the source item.
///
/// Callers must serialize migrations and keep guests blocked until migration
/// completes. Any supplied authentication context belongs to the caller and
/// must be invalidated there when it is no longer needed.
public struct KeychainGroupMigration {
    private let store: any KeychainMigrationStore

    public init(store: any KeychainMigrationStore) {
        self.store = store
    }

    public func move(
        _ item: KeychainMigrationItem,
        from sourceGroup: String,
        to destinationGroup: String
    ) throws -> KeychainMigrationOutcome {
        guard hasNonemptyIdentifier(sourceGroup),
              hasNonemptyIdentifier(destinationGroup),
              sourceGroup != destinationGroup else {
            throw KeychainGroupMigrationError.invalidGroups
        }
        guard hasNonemptyIdentifier(item.service), hasNonemptyIdentifier(item.account) else {
            throw KeychainGroupMigrationError.invalidItem
        }

        let sourceData = try store.read(item, accessGroup: sourceGroup)
        let destinationData = try store.read(item, accessGroup: destinationGroup)

        guard let expectedData = sourceData else {
            return destinationData == nil ? .absent : .alreadyMoved
        }

        if let destinationData, destinationData != expectedData {
            throw KeychainGroupMigrationError.conflictingItems
        }

        if destinationData == nil {
            try store.insert(expectedData, item: item, accessGroup: destinationGroup)
        }

        let verifiedDestination = try store.read(item, accessGroup: destinationGroup)
        guard verifiedDestination == expectedData else {
            throw KeychainGroupMigrationError.destinationVerificationFailed
        }

        let currentSource = try store.read(item, accessGroup: sourceGroup)
        guard currentSource == expectedData else {
            throw KeychainGroupMigrationError.sourceChanged
        }

        try store.remove(item, accessGroup: sourceGroup)

        let remainingSource = try store.read(item, accessGroup: sourceGroup)
        guard remainingSource == nil else {
            throw KeychainGroupMigrationError.sourceRemovalNotConfirmed
        }

        let finalDestination = try store.read(item, accessGroup: destinationGroup)
        guard finalDestination == expectedData else {
            throw KeychainGroupMigrationError.destinationVerificationFailed
        }

        return .moved
    }
}

private func hasNonemptyIdentifier(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

#if canImport(Security) && canImport(LocalAuthentication)
/// A generic-password Keychain adapter for an exact service, account, and
/// caller-supplied access group. It never updates an existing item.
public final class SecurityKeychainMigrationStore: KeychainMigrationStore {
    private let context: LAContext?

    public init(context: LAContext? = nil) {
        self.context = context
    }

    public func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? {
        try validate(item, accessGroup: accessGroup)

        var query = baseQuery(item, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        addAuthenticationContext(to: &query)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainGroupMigrationError.invalidItem
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainGroupMigrationError.unexpectedStatus(Int32(status))
        }
    }

    public func insert(
        _ data: Data,
        item: KeychainMigrationItem,
        accessGroup: String
    ) throws {
        try validate(item, accessGroup: accessGroup)

        var query = baseQuery(item, accessGroup: accessGroup)
        query[kSecValueData as String] = data
        addAuthenticationContext(to: &query)

        switch item.protection {
        case .whenUnlockedDeviceOnly:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .biometryCurrentSet:
            var creationError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .biometryCurrentSet,
                &creationError
            ) else {
                _ = creationError?.takeRetainedValue()
                throw KeychainGroupMigrationError.accessControlCreationFailed
            }
            query[kSecAttrAccessControl as String] = accessControl
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainGroupMigrationError.unexpectedStatus(Int32(status))
        }
    }

    public func remove(_ item: KeychainMigrationItem, accessGroup: String) throws {
        try validate(item, accessGroup: accessGroup)

        var query = baseQuery(item, accessGroup: accessGroup)
        addAuthenticationContext(to: &query)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainGroupMigrationError.unexpectedStatus(Int32(status))
        }
    }

    private func baseQuery(
        _ item: KeychainMigrationItem,
        accessGroup: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }

    private func addAuthenticationContext(to query: inout [String: Any]) {
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
    }

    private func validate(_ item: KeychainMigrationItem, accessGroup: String) throws {
        guard hasNonemptyIdentifier(item.service), hasNonemptyIdentifier(item.account) else {
            throw KeychainGroupMigrationError.invalidItem
        }
        guard hasNonemptyIdentifier(accessGroup) else {
            throw KeychainGroupMigrationError.invalidGroups
        }
    }
}
#endif
