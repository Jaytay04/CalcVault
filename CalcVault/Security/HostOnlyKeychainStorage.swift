import Foundation
import LocalAuthentication
import Security

public struct KeychainAccessGroups: Equatable, Sendable {
    public let legacy: String
    public let hostOnly: String
    public let legacyGroups: [String]

    public init(legacy: String, hostOnly: String, additionalLegacyGroups: [String] = []) throws {
        let sources = [legacy] + additionalLegacyGroups
        guard !hostOnly.isEmpty, sources.allSatisfy({ !$0.isEmpty && $0 != hostOnly }),
              Set(sources).count == sources.count else {
            throw HostOnlyKeychainStorageError.identityUnavailable
        }
        self.legacy = legacy
        self.hostOnly = hostOnly
        self.legacyGroups = sources
    }
}

public enum HostOnlyKeychainStorageError: Error, Equatable, LocalizedError {
    case identityUnavailable
    case duplicateItem
    case invalidItem
    case invalidInventory
    case legacyCredentialPresent
    case protectionMismatch
    case unexpectedStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            return "Protected Keychain access is unavailable for this app signature. Existing credentials were not replaced."
        case .duplicateItem:
            return "Credentials already exist and were not overwritten."
        case .invalidItem:
            return "The stored credential is unavailable or invalid. It was not replaced."
        case .invalidInventory:
            return "The credential inventory is empty or contains an invalid or duplicate identity."
        case .legacyCredentialPresent:
            return "A credential copy exists in a supported legacy Keychain group."
        case .protectionMismatch:
            return "The credential protection does not match the required policy. Existing credentials were not replaced."
        case .unexpectedStatus(let status):
            return "Protected Keychain operation failed (status \(status)). Existing configuration was not replaced."
        }
    }
}

fileprivate enum NativeGuestCredentialBoundaryStage: String, Sendable, Equatable {
    case inventory
    case groupResolution = "group-resolution"
    case legacyPresence = "legacy-presence"
    case requiredProtection = "required-protection"
    case optionalProtection = "optional-protection"
}

/// Sanitized, stable diagnostic for a native guest credential boundary check.
/// It intentionally contains no Keychain identity or underlying error text.
public struct NativeGuestCredentialBoundaryFailure: Error, Sendable, Equatable {
    private let stage: NativeGuestCredentialBoundaryStage
    private let itemIndex: Int?
    private let groupIndex: Int?
    private let reason: String

    fileprivate init(
        stage: NativeGuestCredentialBoundaryStage,
        itemIndex: Int?,
        groupIndex: Int?,
        error: any Error
    ) {
        self.stage = stage
        self.itemIndex = itemIndex.map { min($0, 99) }
        self.groupIndex = groupIndex.map { min($0, 99) }

        guard let error = error as? HostOnlyKeychainStorageError else {
            reason = "unclassified"
            return
        }

        switch error {
        case .identityUnavailable:
            reason = "identity-unavailable"
        case .duplicateItem:
            reason = "duplicate-item"
        case .invalidItem:
            reason = "invalid-item"
        case .invalidInventory:
            reason = "invalid-inventory"
        case .legacyCredentialPresent:
            reason = "legacy-credential-present"
        case .protectionMismatch:
            reason = "protection-mismatch"
        case .unexpectedStatus(let status):
            reason = "status:\(status)"
        }
    }

    public var diagnosticCode: String {
        let item = itemIndex.map { ".item-\($0)" } ?? ""
        let group = groupIndex.map { ".group-\($0)" } ?? ""
        return "native-guest-boundary.\(stage.rawValue)\(item)\(group).\(reason)"
    }

    /// Whether a biometric-authenticated metadata retry is appropriate for
    /// this exact Keychain interaction failure. This deliberately excludes
    /// legacy scans, identity/group failures, missing items, and all other
    /// Security statuses.
    public func requiresBiometricAuthentication(biometricEnabled: Bool) -> Bool {
        guard groupIndex == nil, reason == "status:-25308", let itemIndex else { return false }
        return (stage == .requiredProtection && itemIndex == 2 && biometricEnabled)
            || (stage == .optionalProtection && itemIndex == 1 && !biometricEnabled)
    }
}

private struct KeychainCredentialIdentity: Hashable {
    let service: String
    let account: String
}

public protocol HostOnlyKeychainBackend: KeychainMigrationStore {
    func contains(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool
    func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool
    func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws
}

/// Serializes scoped credential operations. Native guests are not enabled by
/// this type: integrations must explicitly apply the credential boundary check
/// and enforce guest lifecycle revocation.
public final class HostOnlyKeychainStorage: @unchecked Sendable {
    private static let operationLock = NSRecursiveLock()
    private let groups: () throws -> KeychainAccessGroups
    private let backend: (LAContext?) -> any HostOnlyKeychainBackend

    public init(
        groups: @escaping () throws -> KeychainAccessGroups = { try KeychainGroupDiscovery.shared.resolve() },
        backend: @escaping (LAContext?) -> any HostOnlyKeychainBackend = { ScopedSecurityKeychainBackend(context: $0) }
    ) {
        self.groups = groups
        self.backend = backend
    }

    public func read(_ item: KeychainMigrationItem, context: LAContext? = nil) throws -> Data? {
        try locked {
            let scope = try groups()
            let store = backend(context)
            try migrate(item, scope: scope, store: store)
            return try store.read(item, accessGroup: scope.hostOnly)
        }
    }

    public func write(_ data: Data, item: KeychainMigrationItem, context: LAContext? = nil) throws {
        try locked {
            let scope = try groups()
            let store = backend(context)
            // Never turn a new write into an overwrite of a legacy credential.
            for group in scope.legacyGroups + [scope.hostOnly] {
                if try store.contains(item, accessGroup: group) {
                    throw HostOnlyKeychainStorageError.duplicateItem
                }
            }
            try store.insert(data, item: item, accessGroup: scope.hostOnly)
        }
    }

    /// Performs a point-in-time, metadata-only check that none of the supplied
    /// credential identities exists in a supported legacy access group. It
    /// does not read credential data or inspect host-only destination state.
    /// Success is not guest authorization, guest isolation, or destination
    /// protection; integration must separately require an active authenticated
    /// session and valid destination state.
    public func assertNoLegacyCopies(_ items: [KeychainMigrationItem]) throws {
        try locked {
            guard !items.isEmpty else { throw HostOnlyKeychainStorageError.invalidInventory }

            var identities = Set<KeychainCredentialIdentity>()
            for item in items {
                guard !item.service.isEmpty, !item.account.isEmpty else {
                    throw HostOnlyKeychainStorageError.invalidInventory
                }
                let identity = KeychainCredentialIdentity(service: item.service, account: item.account)
                guard identities.insert(identity).inserted else {
                    throw HostOnlyKeychainStorageError.invalidInventory
                }
            }

            let scope = try groups()
            let store = backend(nil)
            var foundLegacyCopy = false
            for item in items {
                for group in scope.legacyGroups {
                    if try store.contains(item, accessGroup: group) {
                        foundLegacyCopy = true
                    }
                }
            }
            guard !foundLegacyCopy else {
                throw HostOnlyKeychainStorageError.legacyCredentialPresent
            }
        }
    }

    /// Verifies that supported legacy groups contain none of the supplied
    /// credentials and that required and present optional credentials in the
    /// host-only group meet their declared protection policy. This is a
    /// point-in-time storage boundary check, not guest authorization or proof
    /// that public Keychain attributes expose exact biometric ACL flags.
    public func assertGuestCredentialBoundary(
        required: [KeychainMigrationItem],
        optional: [KeychainMigrationItem],
        context: LAContext? = nil,
        diagnosticErrors: Bool = false
    ) throws {
        try locked {
            var stage = NativeGuestCredentialBoundaryStage.inventory
            var itemIndex: Int?
            var groupIndex: Int?
            do {
                guard !required.isEmpty else { throw HostOnlyKeychainStorageError.invalidInventory }
                let items = required + optional
                guard !items.isEmpty else { throw HostOnlyKeychainStorageError.invalidInventory }

                var identities = Set<KeychainCredentialIdentity>()
                for (index, item) in items.enumerated() {
                    itemIndex = index
                    groupIndex = nil
                    guard !item.service.isEmpty, !item.account.isEmpty else {
                        throw HostOnlyKeychainStorageError.invalidInventory
                    }
                    let identity = KeychainCredentialIdentity(service: item.service, account: item.account)
                    guard identities.insert(identity).inserted else {
                        throw HostOnlyKeychainStorageError.invalidInventory
                    }
                }

                stage = .groupResolution
                itemIndex = nil
                groupIndex = nil
                let scope = try groups()
                let store = backend(context)

                stage = .legacyPresence
                var foundLegacyCopy = false
                var firstLegacyLocation: (item: Int, group: Int)?
                for (currentItemIndex, item) in items.enumerated() {
                    for (currentGroupIndex, group) in scope.legacyGroups.enumerated() {
                        itemIndex = currentItemIndex
                        groupIndex = currentGroupIndex
                        if try store.contains(item, accessGroup: group) {
                            foundLegacyCopy = true
                            if firstLegacyLocation == nil {
                                firstLegacyLocation = (currentItemIndex, currentGroupIndex)
                            }
                        }
                    }
                }
                if let firstLegacyLocation {
                    itemIndex = firstLegacyLocation.item
                    groupIndex = firstLegacyLocation.group
                }
                guard !foundLegacyCopy else {
                    throw HostOnlyKeychainStorageError.legacyCredentialPresent
                }

                stage = .requiredProtection
                groupIndex = nil
                var missingRequiredCredential = false
                var firstMissingRequiredIndex: Int?
                for (currentItemIndex, item) in required.enumerated() {
                    itemIndex = currentItemIndex
                    let isPresent = try store.validateProtection(item, accessGroup: scope.hostOnly)
                    if !isPresent {
                        missingRequiredCredential = true
                        if firstMissingRequiredIndex == nil {
                            firstMissingRequiredIndex = currentItemIndex
                        }
                    }
                }
                stage = .optionalProtection
                itemIndex = nil
                for (currentItemIndex, item) in optional.enumerated() {
                    itemIndex = currentItemIndex
                    // A false result means only that this optional identity is absent.
                    _ = try store.validateProtection(item, accessGroup: scope.hostOnly)
                }
                stage = .requiredProtection
                itemIndex = firstMissingRequiredIndex
                groupIndex = nil
                guard !missingRequiredCredential else { throw HostOnlyKeychainStorageError.invalidItem }
            } catch {
                guard diagnosticErrors else { throw error }
                throw NativeGuestCredentialBoundaryFailure(
                    stage: stage,
                    itemIndex: itemIndex,
                    groupIndex: groupIndex,
                    error: error
                )
            }
        }
    }

    public func replace(_ data: Data, item: KeychainMigrationItem) throws {
        guard item.protection == .whenUnlockedDeviceOnly else {
            throw HostOnlyKeychainStorageError.protectionMismatch
        }
        try locked {
            let scope = try groups()
            let store = backend(nil)
            try migrate(item, scope: scope, store: store)
            guard try store.contains(item, accessGroup: scope.hostOnly) else { throw HostOnlyKeychainStorageError.invalidItem }
            try store.replace(data, item: item, accessGroup: scope.hostOnly)
        }
    }

    /// Explicit deletion only: callers must request removal of this exact item.
    /// Migration never uses this method; it removes its verified source directly.
    public func delete(_ item: KeychainMigrationItem) throws {
        try locked {
            let scope = try groups()
            let store = backend(nil)
            for group in scope.legacyGroups { try store.remove(item, accessGroup: group) }
            try store.remove(item, accessGroup: scope.hostOnly)
        }
    }

    private func migrate(_ item: KeychainMigrationItem, scope: KeychainAccessGroups,
                         store: any HostOnlyKeychainBackend) throws {
        // Preflight all explicitly supported historical locations before deleting
        // any source, so conflicts cannot be silently resolved by group order.
        var expected: Data?
        for group in scope.legacyGroups + [scope.hostOnly] {
            if let value = try store.read(item, accessGroup: group) {
                if let expected, expected != value { throw KeychainGroupMigrationError.conflictingItems }
                expected = value
            }
        }
        for source in scope.legacyGroups {
            _ = try KeychainGroupMigration(store: store).move(item, from: source, to: scope.hostOnly)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        Self.operationLock.lock()
        defer { Self.operationLock.unlock() }
        return try body()
    }
}

/// Real Security adapter; every credential query names exactly one group.
public final class ScopedSecurityKeychainBackend: HostOnlyKeychainBackend {
    private let migrationStore: SecurityKeychainMigrationStore
    private let context: LAContext?

    public init(context: LAContext? = nil) {
        self.context = context
        self.migrationStore = SecurityKeychainMigrationStore(context: context)
    }

    public func read(_ item: KeychainMigrationItem, accessGroup: String) throws -> Data? {
        guard let data = try migrationStore.read(item, accessGroup: accessGroup) else { return nil }
        // A present destination is not accepted solely because its bytes exist.
        try verifyProtection(item, accessGroup: accessGroup)
        return data
    }

    public func insert(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        try migrationStore.insert(data, item: item, accessGroup: accessGroup)
    }

    public func remove(_ item: KeychainMigrationItem, accessGroup: String) throws {
        try migrationStore.remove(item, accessGroup: accessGroup)
    }

    public func contains(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        try attributes(item, accessGroup: accessGroup) != nil
    }

    public func validateProtection(_ item: KeychainMigrationItem, accessGroup: String) throws -> Bool {
        guard let values = try attributes(item, accessGroup: accessGroup) else { return false }
        try verifyProtection(item, accessGroup: accessGroup, attributes: values)
        return true
    }

    public func replace(_ data: Data, item: KeychainMigrationItem, accessGroup: String) throws {
        try verifyProtection(item, accessGroup: accessGroup)
        let status = SecItemUpdate(try query(item, accessGroup: accessGroup) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw HostOnlyKeychainStorageError.unexpectedStatus(status) }
    }

    private func verifyProtection(_ item: KeychainMigrationItem, accessGroup: String) throws {
        guard let values = try attributes(item, accessGroup: accessGroup) else {
            throw HostOnlyKeychainStorageError.invalidItem
        }
        try verifyProtection(item, accessGroup: accessGroup, attributes: values)
    }

    private func verifyProtection(
        _ item: KeychainMigrationItem,
        accessGroup: String,
        attributes values: [String: Any]
    ) throws {
        let accessibility = values[kSecAttrAccessible as String] as? String
        let expected = item.protection == .biometryCurrentSet
            ? kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard accessibility == expected as String,
              values[kSecAttrAccessGroup as String] as? String == accessGroup else {
            throw HostOnlyKeychainStorageError.protectionMismatch
        }
        if item.protection == .biometryCurrentSet {
            guard let accessControl = values[kSecAttrAccessControl as String],
                  CFGetTypeID(accessControl as CFTypeRef) == SecAccessControlGetTypeID() else {
                throw HostOnlyKeychainStorageError.protectionMismatch
            }
        }
        // Public attributes reveal an access-control object but not its exact
        // biometric flags or the enrolled biometric set. Enrollment invalidation
        // still requires its own device test.
    }

    private func attributes(_ item: KeychainMigrationItem, accessGroup: String) throws -> [String: Any]? {
        var request = try query(item, accessGroup: accessGroup)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Metadata inspection must never trigger an implicit biometric prompt.
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HostOnlyKeychainStorageError.unexpectedStatus(status) }
        guard let values = result as? [String: Any] else { throw HostOnlyKeychainStorageError.invalidItem }
        return values
    }

    private func query(_ item: KeychainMigrationItem, accessGroup: String) throws -> [String: Any] {
        guard !item.service.isEmpty, !item.account.isEmpty, !accessGroup.isEmpty else {
            throw HostOnlyKeychainStorageError.invalidItem
        }
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service, kSecAttrAccount as String: item.account,
            kSecAttrAccessGroup as String: accessGroup, kSecAttrSynchronizable as String: false]
        if let context { result[kSecUseAuthenticationContext as String] = context }
        return result
    }
}
