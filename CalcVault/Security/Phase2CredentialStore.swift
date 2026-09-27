import Foundation
import LocalAuthentication
import Sodium

public enum Phase2CredentialStoreError: Error, Equatable {
    case duplicateItem
    case invalidItem
    case unexpectedStatus(Int32)
}

/// Exact-account, device-only Keychain storage for Phase 2 metadata. This is
/// intentionally separate from the biometric root-key copy.
public protocol Phase2CredentialPersisting: AnyObject {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func replace(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public final class UnlockedDeviceKeychainStore: Phase2CredentialPersisting, @unchecked Sendable {
    public let service: String
    private let storage: HostOnlyKeychainStorage

    public init(
        service: String,
        storage: HostOnlyKeychainStorage = HostOnlyKeychainStorage()
    ) {
        self.service = service
        self.storage = storage
    }

    public func read(account: String) throws -> Data? {
        try mapDuplicateItemError(to: Phase2CredentialStoreError.duplicateItem) {
            try storage.read(migrationItem(account: account))
        }
    }

    public func write(_ data: Data, account: String) throws {
        try mapDuplicateItemError(to: Phase2CredentialStoreError.duplicateItem) {
            try storage.write(data, item: migrationItem(account: account))
        }
    }

    public func replace(_ data: Data, account: String) throws {
        try mapDuplicateItemError(to: Phase2CredentialStoreError.duplicateItem) {
            try storage.replace(data, item: migrationItem(account: account))
        }
    }

    public func delete(account: String) throws {
        try mapDuplicateItemError(to: Phase2CredentialStoreError.duplicateItem) {
            try storage.delete(migrationItem(account: account))
        }
    }

    private func migrationItem(account: String) -> KeychainMigrationItem {
        KeychainMigrationItem(
            service: service,
            account: account,
            protection: .whenUnlockedDeviceOnly
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

public protocol BiometricRootKeyPersisting: AnyObject {
    func write(_ data: Data, account: String) throws
    func read(account: String, context: LAContext?) throws -> Data?
    func delete(account: String) throws
}

extension KeychainStore: BiometricRootKeyPersisting {}

public struct PassphraseKDFParameters: Codable, Equatable, Sendable {
    public let algorithm: String
    public let operationsLimit: Int
    public let memoryLimit: Int

    public init(algorithm: String = "argon2id13", operationsLimit: Int, memoryLimit: Int) {
        self.algorithm = algorithm
        self.operationsLimit = operationsLimit
        self.memoryLimit = memoryLimit
    }
}

public struct Phase2PassphraseEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let vaultID: UUID
    public let passphraseEncoding: String
    public let kdf: PassphraseKDFParameters
    public let salt: Data
    public let wrappedRootKey: Data
    public let biometricEnabled: Bool
}

public enum Phase2EnrollmentState: Equatable, Sendable {
    case unconfigured
    case configured(biometricEnabled: Bool)
    case inconsistent
}

public enum Phase2CredentialError: Error, Equatable, LocalizedError, Sendable {
    case invalidNavigationSequence
    case invalidReplacementNavigationSequence
    case passphraseTooShort
    case alreadyConfigured
    case incompleteConfiguration
    case invalidEnvelope
    case keyDerivationFailed
    case encryptionFailed
    case authenticationFailed
    case biometricUnavailable
    case randomGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidNavigationSequence:
            return "The calculator entry sequence must contain 8 to 12 ASCII digits."
        case .invalidReplacementNavigationSequence:
            return "The replacement sequence must contain 1 to 12 ASCII digits."
        case .passphraseTooShort:
            return "Use an independent vault passphrase with at least 12 characters."
        case .alreadyConfigured:
            return "CalcVault is already configured and was not overwritten."
        case .incompleteConfiguration:
            return "The existing CalcVault configuration is incomplete. It was not replaced."
        case .invalidEnvelope:
            return "The stored authentication envelope is invalid. It was not replaced."
        case .keyDerivationFailed:
            return "Argon2id key derivation failed. Security parameters were not reduced."
        case .encryptionFailed:
            return "The root key could not be wrapped. Setup was not completed."
        case .authenticationFailed:
            return "Authentication failed."
        case .biometricUnavailable:
            return "Biometric access is unavailable. Use the independent vault passphrase."
        case .randomGenerationFailed:
            return "Secure random generation failed. Setup was not completed."
        }
    }
}

/// Phase 2 credential boundary. It creates a random root key and stores only
/// an Argon2id/XChaCha20-Poly1305 envelope plus the separate navigation item.
/// Vault files and manifests remain Phase 3 work.
public final class Phase2CredentialManager: @unchecked Sendable {
    public static let metadataService = "com.jaylintaylor.calcvault.phase2.credentials"
    public static let biometricService = "com.jaylintaylor.calcvault.phase2.biometric-root"
    public static let navigationAccount = "navigation-sequence-v1"
    public static let envelopeAccount = "passphrase-envelope-v1"
    public static let biometricRootAccount = "root-key-v1"

    private let metadataStore: Phase2CredentialPersisting
    private let biometricStore: BiometricRootKeyPersisting
    private let parameters: PassphraseKDFParameters

    public init(
        metadataStore: Phase2CredentialPersisting = UnlockedDeviceKeychainStore(service: metadataService),
        biometricStore: BiometricRootKeyPersisting = KeychainStore(service: biometricService),
        parameters: PassphraseKDFParameters? = nil
    ) {
        self.metadataStore = metadataStore
        self.biometricStore = biometricStore
        let sodium = Sodium()
        self.parameters = parameters ?? PassphraseKDFParameters(
            operationsLimit: sodium.pwHash.OpsLimitInteractive,
            memoryLimit: sodium.pwHash.MemLimitInteractive
        )
    }

    public func enrollmentState() throws -> Phase2EnrollmentState {
        let navigation = try metadataStore.read(account: Self.navigationAccount)
        let envelopeData = try metadataStore.read(account: Self.envelopeAccount)
        switch (navigation, envelopeData) {
        case (nil, nil):
            return .unconfigured
        case (.some(_), nil), (nil, .some(_)):
            return .inconsistent
        case let (.some(navigation), .some(envelopeData)):
            guard let sequence = String(data: navigation, encoding: .utf8),
                  (try? SecretEntryConfiguration(sequence: sequence)) != nil,
                  let envelope = try? JSONDecoder().decode(Phase2PassphraseEnvelope.self, from: envelopeData),
                  (try? validate(envelope: envelope)) != nil else {
                return .inconsistent
            }
            return .configured(biometricEnabled: envelope.biometricEnabled)
        }
    }

    public func navigationSequence() throws -> String? {
        guard let data = try metadataStore.read(account: Self.navigationAccount) else {
            return nil
        }
        guard let sequence = String(data: data, encoding: .utf8),
              (try? SecretEntryConfiguration(sequence: sequence)) != nil else {
            throw Phase2CredentialError.incompleteConfiguration
        }
        return sequence
    }

    public func vaultIdentity() throws -> UUID {
        try loadEnvelope().vaultID
    }

    /// Enrollment never overwrites an existing item. If any new write fails,
    /// it removes only items created by this call and leaves a visible error.
    public func enroll(
        navigationSequence: String,
        passphrase: String,
        enableBiometrics: Bool
    ) throws {
        guard (8...12).contains(navigationSequence.utf8.count),
              (try? SecretEntryConfiguration(sequence: navigationSequence)) != nil else {
            throw Phase2CredentialError.invalidNavigationSequence
        }
        guard passphrase.count >= 12 else {
            throw Phase2CredentialError.passphraseTooShort
        }
        guard try enrollmentState() == .unconfigured else {
            throw Phase2CredentialError.alreadyConfigured
        }

        let sodium = Sodium()
        guard let salt = sodium.randomBytes.buf(length: sodium.pwHash.SaltBytes),
              let rootKey = sodium.randomBytes.buf(length: sodium.aead.xchacha20poly1305ietf.KeyBytes) else {
            throw Phase2CredentialError.randomGenerationFailed
        }

        let vaultID = UUID()
        let provisional = Phase2PassphraseEnvelope(
            version: 1,
            vaultID: vaultID,
            passphraseEncoding: "utf8-exact-v1",
            kdf: parameters,
            salt: Data(salt),
            wrappedRootKey: Data(),
            biometricEnabled: enableBiometrics
        )
        let wrappingKey = try deriveKey(passphrase: passphrase, envelope: provisional, sodium: sodium)
        let wrapped: Bytes? = sodium.aead.xchacha20poly1305ietf.encrypt(
            message: rootKey,
            secretKey: wrappingKey,
            additionalData: Array(associatedData(for: provisional))
        )
        guard let wrapped else {
            throw Phase2CredentialError.encryptionFailed
        }

        let envelope = Phase2PassphraseEnvelope(
            version: provisional.version,
            vaultID: provisional.vaultID,
            passphraseEncoding: provisional.passphraseEncoding,
            kdf: provisional.kdf,
            salt: provisional.salt,
            wrappedRootKey: Data(wrapped),
            biometricEnabled: enableBiometrics
        )
        let encoded = try JSONEncoder().encode(envelope)
        var createdAccounts: [String] = []
        do {
            try metadataStore.write(encoded, account: Self.envelopeAccount)
            createdAccounts.append(Self.envelopeAccount)
            try metadataStore.write(Data(navigationSequence.utf8), account: Self.navigationAccount)
            createdAccounts.append(Self.navigationAccount)
            if enableBiometrics {
                try biometricStore.write(Data(rootKey), account: Self.biometricRootAccount)
            }
        } catch {
            for account in createdAccounts.reversed() {
                try? metadataStore.delete(account: account)
            }
            throw error
        }
    }

    /// Replaces only the navigation item. The caller must require a fresh
    /// passphrase check and an active private session before invoking this.
    /// A failed Keychain update leaves the previous sequence untouched.
    public func replaceNavigationSequence(_ sequence: String) throws {
        guard (try? SecretEntryConfiguration(sequence: sequence)) != nil else {
            throw Phase2CredentialError.invalidReplacementNavigationSequence
        }
        guard case .configured = try enrollmentState() else {
            throw Phase2CredentialError.incompleteConfiguration
        }
        try metadataStore.replace(Data(sequence.utf8), account: Self.navigationAccount)
    }

    public func unlock(passphrase: String) throws -> Data {
        let envelope = try loadEnvelope()
        let sodium = Sodium()
        let wrappingKey = try deriveKey(passphrase: passphrase, envelope: envelope, sodium: sodium)
        guard let rootKey = sodium.aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: Array(envelope.wrappedRootKey),
            secretKey: wrappingKey,
            additionalData: Array(associatedData(for: envelope))
        ), rootKey.count == sodium.aead.xchacha20poly1305ietf.KeyBytes else {
            throw Phase2CredentialError.authenticationFailed
        }
        return Data(rootKey)
    }

    public func unlockWithBiometrics(context: LAContext) throws -> Data {
        let envelope = try loadEnvelope()
        guard envelope.biometricEnabled else {
            throw Phase2CredentialError.biometricUnavailable
        }
        guard let rootKey = try biometricStore.read(account: Self.biometricRootAccount, context: context),
              rootKey.count == Sodium().aead.xchacha20poly1305ietf.KeyBytes else {
            throw Phase2CredentialError.biometricUnavailable
        }
        return rootKey
    }

    private func loadEnvelope() throws -> Phase2PassphraseEnvelope {
        guard let data = try metadataStore.read(account: Self.envelopeAccount) else {
            throw Phase2CredentialError.incompleteConfiguration
        }
        guard let envelope = try? JSONDecoder().decode(Phase2PassphraseEnvelope.self, from: data) else {
            throw Phase2CredentialError.invalidEnvelope
        }
        try validate(envelope: envelope)
        return envelope
    }

    private func validate(envelope: Phase2PassphraseEnvelope) throws {
        guard envelope.version == 1,
              envelope.passphraseEncoding == "utf8-exact-v1",
              envelope.kdf.algorithm == "argon2id13",
              (1...10).contains(envelope.kdf.operationsLimit),
              (8 * 1_024...1_024 * 1_024 * 1_024).contains(envelope.kdf.memoryLimit),
              envelope.salt.count == Sodium().pwHash.SaltBytes,
              envelope.wrappedRootKey.count <= 1_024 else {
            throw Phase2CredentialError.invalidEnvelope
        }
    }

    private func deriveKey(
        passphrase: String,
        envelope: Phase2PassphraseEnvelope,
        sodium: Sodium
    ) throws -> Bytes {
        try validate(envelope: envelope)
        guard let key = sodium.pwHash.hash(
            outputLength: sodium.aead.xchacha20poly1305ietf.KeyBytes,
            passwd: Array(passphrase.utf8),
            salt: Array(envelope.salt),
            opsLimit: envelope.kdf.operationsLimit,
            memLimit: envelope.kdf.memoryLimit,
            alg: .Argon2ID13
        ) else {
            throw Phase2CredentialError.keyDerivationFailed
        }
        return key
    }

    private func associatedData(for envelope: Phase2PassphraseEnvelope) -> Data {
        Data([
            "CalcVault",
            "passphrase-envelope",
            "v\(envelope.version)",
            "vault=\(envelope.vaultID.uuidString.lowercased())",
            "encoding=\(envelope.passphraseEncoding)",
            "kdf=\(envelope.kdf.algorithm)",
            "ops=\(envelope.kdf.operationsLimit)",
            "mem=\(envelope.kdf.memoryLimit)",
            "salt=\(envelope.salt.base64EncodedString())",
            "biometric=\(envelope.biometricEnabled ? 1 : 0)"
        ].joined(separator: "|").utf8)
    }
}
