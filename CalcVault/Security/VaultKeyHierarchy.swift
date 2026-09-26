import Foundation
import Sodium

public struct VaultKeyHierarchy: Sendable {
    public static let rootKeyBytes = 32
    public static let objectKeyBytes = 32
    public static let manifestContext = "CVManV01"
    public static let manifestSubkeyID: UInt64 = 1

    public init() {}

    public func manifestKey(from rootKey: Data) throws -> Data {
        guard rootKey.count == Self.rootKeyBytes else {
            throw VaultFormatError.invalidRootKeyLength(
                expected: Self.rootKeyBytes,
                actual: rootKey.count
            )
        }
        let sodium = Sodium()
        guard let key = sodium.keyDerivation.derive(
            secretKey: Array(rootKey),
            index: Self.manifestSubkeyID,
            length: sodium.aead.xchacha20poly1305ietf.KeyBytes,
            context: Self.manifestContext
        ) else {
            throw VaultFormatError.authenticationFailed
        }
        return Data(key)
    }

    public func generateObjectKey() throws -> Data {
        let stream = Sodium().secretStream.xchacha20poly1305
        return Data(stream.key())
    }
}
