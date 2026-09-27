import Foundation
import LocalAuthentication

public enum KeychainStoreError: Error, Equatable {
    case accessControlCreationFailed
    case duplicateItem
    case itemNotFound
    case invalidItem
    case unexpectedStatus(Int32)
}

/// A narrow wrapper for device-only biometric-protected key data.
public final class KeychainStore {
    public let service: String
    private let storage: HostOnlyKeychainStorage

    public init(
        service: String,
        storage: HostOnlyKeychainStorage = HostOnlyKeychainStorage()
    ) {
        self.service = service
        self.storage = storage
    }

    public func write(_ data: Data, account: String) throws {
        try mapDuplicateItemError(to: KeychainStoreError.duplicateItem) {
            try storage.write(data, item: migrationItem(account: account))
        }
    }

    /// Reads an item and lets Security/LocalAuthentication perform the
    /// protected access check. A caller may supply a fresh LAContext for each
    /// unlock attempt.
    public func read(account: String, context: LAContext? = nil) throws -> Data? {
        try mapDuplicateItemError(to: KeychainStoreError.duplicateItem) {
            try storage.read(migrationItem(account: account), context: context)
        }
    }

    /// Deletes only the exact service/account item requested by the caller.
    /// Missing items are treated as an idempotent success for cleanup paths.
    public func delete(account: String) throws {
        try mapDuplicateItemError(to: KeychainStoreError.duplicateItem) {
            try storage.delete(migrationItem(account: account))
        }
    }

    private func migrationItem(account: String) -> KeychainMigrationItem {
        KeychainMigrationItem(
            service: service,
            account: account,
            protection: .biometryCurrentSet
        )
    }
}

private func mapDuplicateItemError<T>(
    to duplicateError: Error,
    operation: () throws -> T
) throws -> T {
    do {
        return try operation()
    } catch let error as HostOnlyKeychainStorageError {
        if case .duplicateItem = error {
            throw duplicateError
        }
        throw error
    } catch {
        throw error
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
