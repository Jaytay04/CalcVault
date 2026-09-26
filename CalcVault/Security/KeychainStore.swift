import Foundation
import LocalAuthentication
import Security

public enum KeychainStoreError: Error, Equatable {
    case accessControlCreationFailed
    case duplicateItem
    case itemNotFound
    case invalidItem
    case unexpectedStatus(Int32)
}

/// A narrow Keychain wrapper for device-only biometric-protected key data.
///
/// Callers must opt into this store explicitly. Items are created with
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` and the current biometric
/// set, so a missing passcode or changed enrollment fails closed.
public final class KeychainStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func write(_ data: Data, account: String) throws {
        guard let accessControl = makeAccessControl() else {
            throw KeychainStoreError.accessControlCreationFailed
        }

        var query = baseQuery(account: account)
        query[kSecAttrAccessControl as String] = accessControl
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw KeychainStoreError.duplicateItem
        default:
            throw KeychainStoreError.unexpectedStatus(Int32(status))
        }
    }

    /// Reads an item and lets Security/LocalAuthentication perform the
    /// protected access check. A caller may supply a fresh LAContext for each
    /// unlock attempt.
    public func read(account: String, context: LAContext? = nil) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.invalidItem
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(Int32(status))
        }
    }

    /// Deletes only the exact service/account item requested by the caller.
    /// Missing items are treated as an idempotent success for cleanup paths.
    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainStoreError.unexpectedStatus(Int32(status))
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func makeAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        return SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &error
        )
    }
}

public struct KeychainProbeResult {
    public let itemAdded: Bool
    public let protectedReadMatched: Bool
    public let cleanupCompleted: Bool
    public let statusCode: Int32?

    public var succeeded: Bool {
        itemAdded && protectedReadMatched && cleanupCompleted
    }

    public init(
        itemAdded: Bool,
        protectedReadMatched: Bool,
        cleanupCompleted: Bool,
        statusCode: Int32?
    ) {
        self.itemAdded = itemAdded
        self.protectedReadMatched = protectedReadMatched
        self.cleanupCompleted = cleanupCompleted
        self.statusCode = statusCode
    }
}

/// Probes the selected access policy with a unique, disposable fixture item.
/// It never reads, updates, or deletes an existing account.
public struct KeychainProbe {
    public static let service = "com.calcvault.phase0.keychain-probe"

    private let store: KeychainStore

    public init(store: KeychainStore = KeychainStore(service: KeychainProbe.service)) {
        self.store = store
    }

    public func run(context: LAContext? = nil) -> KeychainProbeResult {
        let account = "fixture-\(UUID().uuidString)"
        let fixture = Data((0..<32).map(UInt8.init))
        var itemAdded = false
        var protectedReadMatched = false
        var statusCode: Int32?

        do {
            try store.write(fixture, account: account)
            itemAdded = true
            protectedReadMatched = try store.read(account: account, context: context) == fixture
        } catch let error as KeychainStoreError {
            statusCode = error.statusCode
        } catch {
            statusCode = nil
        }

        let cleanupCompleted: Bool
        do {
            try store.delete(account: account)
            cleanupCompleted = true
        } catch let error as KeychainStoreError {
            cleanupCompleted = false
            statusCode = statusCode ?? error.statusCode
        } catch {
            cleanupCompleted = false
        }

        return KeychainProbeResult(
            itemAdded: itemAdded,
            protectedReadMatched: protectedReadMatched,
            cleanupCompleted: cleanupCompleted,
            statusCode: statusCode
        )
    }
}

private extension KeychainStoreError {
    var statusCode: Int32? {
        if case let .unexpectedStatus(status) = self {
            return status
        }
        return nil
    }
}
