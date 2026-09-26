import Foundation
import Sodium

/// Errors raised by the Phase 0 authenticated-encryption exercise.
public enum AuthenticatedCipherError: Error, Equatable {
    case invalidKeyLength(expected: Int, actual: Int)
    case encryptionFailed
    case authenticationFailed
}

/// A small, testable wrapper around libsodium's SecretBox primitive.
///
/// SecretBox generates and prepends a fresh nonce for every encryption. The
/// returned value is therefore self-contained and can be passed directly to
/// `decrypt(_:using:)`. This type is intentionally limited to a single
/// authenticated message; large vault objects will use secretstream in a
/// later phase.
public struct AuthenticatedCipher {
    private let sodium: Sodium

    public init(sodium: Sodium = Sodium()) {
        self.sodium = sodium
    }

    /// Generates a fresh 256-bit SecretBox key using libsodium's CSPRNG.
    public func generateKey() -> Data {
        Data(sodium.secretBox.key())
    }

    /// Encrypts and authenticates one message with a fresh random nonce.
    public func encrypt(_ plaintext: Data, using key: Data) throws -> Data {
        try validate(key: key)

        // swift-sodium exposes several overloads with identical arguments and
        // different return shapes. Pin the combined nonce+ciphertext overload.
        let sealedMessage: Bytes? = sodium.secretBox.seal(
            message: Array(plaintext),
            secretKey: Array(key)
        )
        guard let sealedMessage else {
            throw AuthenticatedCipherError.encryptionFailed
        }

        return Data(sealedMessage)
    }

    /// Authenticates and decrypts a SecretBox message.
    public func decrypt(_ ciphertext: Data, using key: Data) throws -> Data {
        try validate(key: key)

        guard let opened = sodium.secretBox.open(
            nonceAndAuthenticatedCipherText: Array(ciphertext),
            secretKey: Array(key)
        ) else {
            throw AuthenticatedCipherError.authenticationFailed
        }

        return Data(opened)
    }

    private func validate(key: Data) throws {
        let expected = sodium.secretBox.KeyBytes
        guard key.count == expected else {
            throw AuthenticatedCipherError.invalidKeyLength(
                expected: expected,
                actual: key.count
            )
        }
    }
}
