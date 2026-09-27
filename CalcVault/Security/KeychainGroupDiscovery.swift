import Foundation
import Security

/// Discovers the signing prefix through a disposable public-Keychain operation,
/// not a hardcoded Team ID or a private entitlement-reading API. Both target
/// groups must independently pass add/read/delete controls before use.
public final class KeychainGroupDiscovery: @unchecked Sendable {
    public static let shared = KeychainGroupDiscovery()
    private let lock = NSLock()
    private var cached: KeychainAccessGroups?
    private let defaultGroup: () throws -> String
    private let verifyGroup: (String) throws -> Void
    private let bundleIdentifier: () -> String?

    public init(
        defaultGroup: @escaping () throws -> String = { try KeychainGroupDiscovery.probe(group: nil) },
        verifyGroup: @escaping (String) throws -> Void = { _ = try KeychainGroupDiscovery.probe(group: $0) },
        bundleIdentifier: @escaping () -> String? = { Bundle.main.bundleIdentifier }
    ) {
        self.defaultGroup = defaultGroup
        self.verifyGroup = verifyGroup
        self.bundleIdentifier = bundleIdentifier
    }

    public func resolve() throws -> KeychainAccessGroups {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let bundleIdentifier = bundleIdentifier() else { throw HostOnlyKeychainStorageError.identityUnavailable }
        let groups = try Self.deriveGroups(defaultGroup: defaultGroup(), bundleIdentifier: bundleIdentifier)
        // Do not interpret an inaccessible group as an empty credential store.
        for source in groups.legacyGroups { try verifyGroup(source) }
        try verifyGroup(groups.hostOnly)
        cached = groups
        return groups
    }

    public static func deriveGroups(defaultGroup: String, bundleIdentifier: String) throws -> KeychainAccessGroups {
        let base = "com.jaylintaylor.calcvault"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        func valid(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        guard bundleIdentifier == base || bundleIdentifier.hasPrefix(base + "."),
              bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ valid(String($0)) }),
              let delimiter = defaultGroup.firstIndex(of: ".") else {
            throw HostOnlyKeychainStorageError.identityUnavailable
        }
        let prefix = String(defaultGroup[..<delimiter])
        guard valid(prefix),
              defaultGroup == prefix + "." + base || defaultGroup == prefix + "." + bundleIdentifier else {
            throw HostOnlyKeychainStorageError.identityUnavailable
        }
        let source = prefix + "." + bundleIdentifier
        let baseSource = prefix + "." + base
        return try KeychainAccessGroups(legacy: source,
                                       hostOnly: prefix + "." + base + ".hostonly",
                                       additionalLegacyGroups: source == baseSource ? [] : [baseSource])
    }

    /// The sole intentionally group-unspecified add is a new, non-secret
    /// identity fixture. Credential services are never queried without a group.
    public static func probe(group: String?) throws -> String {
        let service = "com.jaylintaylor.calcvault.keychain-identity-probe"
        let account = UUID().uuidString
        let marker = Data(UUID().uuidString.utf8)
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: marker, kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw HostOnlyKeychainStorageError.unexpectedStatus(status) }
        let attributes = result as? [String: Any]
        // Prefer the returned persistent reference; otherwise cleanup remains
        // restricted to the newly generated diagnostic service/account only.
        var cleanup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        if let reference = attributes?[kSecValuePersistentRef as String] as? Data {
            cleanup = [kSecValuePersistentRef as String: reference]
        } else if let group {
            cleanup[kSecAttrAccessGroup as String] = group
        }
        do {
            guard let actualGroup = attributes?[kSecAttrAccessGroup as String] as? String,
                  !actualGroup.isEmpty, group == nil || actualGroup == group,
                  attributes?[kSecAttrService as String] as? String == service,
                  attributes?[kSecAttrAccount as String] as? String == account,
                  attributes?[kSecValuePersistentRef as String] is Data else {
                throw HostOnlyKeychainStorageError.identityUnavailable
            }
            let read: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: actualGroup, kSecAttrSynchronizable as String: false,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var readResult: CFTypeRef?
            let readStatus = SecItemCopyMatching(read as CFDictionary, &readResult)
            guard readStatus == errSecSuccess, readResult as? Data == marker else {
                throw HostOnlyKeychainStorageError.identityUnavailable
            }
            let deleteStatus = SecItemDelete(cleanup as CFDictionary)
            guard deleteStatus == errSecSuccess else { throw HostOnlyKeychainStorageError.unexpectedStatus(deleteStatus) }
            return actualGroup
        } catch {
            _ = SecItemDelete(cleanup as CFDictionary)
            throw error
        }
    }
}
