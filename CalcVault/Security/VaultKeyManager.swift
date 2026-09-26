import Foundation

/// Result of the Phase 0 crypto smoke exercise.
///
/// The fixture is synthetic and is never persisted. The generated key is
/// deliberately not included in this result so callers cannot accidentally
/// treat a smoke-test key as a vault key.
public struct DummyCryptoExerciseResult {
    public let plaintext: Data
    public let ciphertext: Data
    public let decrypted: Data
    public let tamperedCiphertextRejected: Bool

    public var roundTripSucceeded: Bool {
        decrypted == plaintext
    }

    public init(
        plaintext: Data,
        ciphertext: Data,
        decrypted: Data,
        tamperedCiphertextRejected: Bool
    ) {
        self.plaintext = plaintext
        self.ciphertext = ciphertext
        self.decrypted = decrypted
        self.tamperedCiphertextRejected = tamperedCiphertextRejected
    }
}

/// Creates fresh key material and exercises authenticated encryption with
/// disposable data. Persistent vault key wrapping is intentionally out of
/// scope for Phase 0.
public struct VaultKeyManager {
    private let cipher: AuthenticatedCipher

    public init(cipher: AuthenticatedCipher = AuthenticatedCipher()) {
        self.cipher = cipher
    }

    public func generateKey() -> Data {
        cipher.generateKey()
    }

    public func runDummyExercise() throws -> DummyCryptoExerciseResult {
        let plaintext = Data("CalcVault Phase 0 dummy fixture".utf8)
        let key = generateKey()
        let ciphertext = try cipher.encrypt(plaintext, using: key)
        let decrypted = try cipher.decrypt(ciphertext, using: key)

        var tampered = ciphertext
        if let firstIndex = tampered.indices.first {
            tampered[firstIndex] ^= 0x01
        }

        let tamperedCiphertextRejected: Bool
        do {
            _ = try cipher.decrypt(tampered, using: key)
            tamperedCiphertextRejected = false
        } catch AuthenticatedCipherError.authenticationFailed {
            tamperedCiphertextRejected = true
        }

        return DummyCryptoExerciseResult(
            plaintext: plaintext,
            ciphertext: ciphertext,
            decrypted: decrypted,
            tamperedCiphertextRejected: tamperedCiphertextRejected
        )
    }
}
