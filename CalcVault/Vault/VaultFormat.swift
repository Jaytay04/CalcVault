import Foundation

public enum VaultFormatError: Error, Equatable, LocalizedError, Sendable {
    case invalidRootKeyLength(expected: Int, actual: Int)
    case unsupportedVersion(Int)
    case malformedHeader
    case invalidManifest
    case invalidObject
    case identityMismatch
    case authenticationFailed
    case truncated
    case unexpectedTrailingData
    case resourceLimitExceeded
    case missingFinalTag
    case staleSession
    case notInitialized
    case alreadyInitialized
    case missingInitializedVault
    case inconsistentStorage
    case operationCancelled
    case itemNotFound
    case folderNotEmpty
    case invalidName
    case unsupportedImport
    case unsupportedPreview
    case insufficientSpace
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRootKeyLength(let expected, let actual):
            return "The vault root key must contain \(expected) bytes; received \(actual)."
        case .unsupportedVersion(let version):
            return "Vault format version \(version) is not supported. No replacement was created."
        case .malformedHeader:
            return "The vault header is malformed. No replacement was created."
        case .invalidManifest:
            return "The encrypted vault manifest is invalid. No replacement was created."
        case .invalidObject:
            return "An encrypted vault object is invalid."
        case .identityMismatch:
            return "The vault identity does not match the authenticated credentials."
        case .authenticationFailed:
            return "Vault data authentication failed. No replacement was created."
        case .truncated:
            return "Encrypted vault data is truncated."
        case .unexpectedTrailingData:
            return "Encrypted vault data contains unexpected trailing bytes."
        case .resourceLimitExceeded:
            return "Vault data exceeds the supported resource limits."
        case .missingFinalTag:
            return "The encrypted object is incomplete because its final tag is missing."
        case .staleSession:
            return "The private session expired before the vault operation completed."
        case .notInitialized:
            return "Encrypted vault storage has not been initialized."
        case .alreadyInitialized:
            return "Encrypted vault storage is already initialized and was not replaced."
        case .missingInitializedVault:
            return "The initialized vault is missing or unreadable. No empty replacement was created."
        case .inconsistentStorage:
            return "Vault storage is inconsistent. Existing data was preserved."
        case .operationCancelled:
            return "The vault operation was cancelled. The last committed state was preserved."
        case .itemNotFound:
            return "The requested vault item no longer exists."
        case .folderNotEmpty:
            return "The folder is not empty. Move or delete its contents first."
        case .invalidName:
            return "The name is empty or exceeds the supported length."
        case .unsupportedImport:
            return "The selected item is not a supported regular file."
        case .unsupportedPreview:
            return "This item cannot be previewed safely in the current version."
        case .insufficientSpace:
            return "There is not enough local storage to complete this operation. The existing vault was preserved."
        case .ioFailure(let message):
            return "Vault storage failed: \(message)"
        }
    }
}

public enum VaultFormatV1 {
    public static let version: UInt16 = 1
    public static let manifestPlaintextLimit = 8 * 1_024 * 1_024
    public static let itemCountLimit = 10_000
    public static let displayNameByteLimit = 1_024
    public static let mediaTypeByteLimit = 255
    public static let objectChunkSize = 65_536
    public static let objectPlaintextLimit: UInt64 = 256 * 1_024 * 1_024 * 1_024
    public static let notePlaintextLimit: UInt64 = 1 * 1_024 * 1_024
    public static let textPreviewLimit: UInt64 = 2 * 1_024 * 1_024
    public static let imagePreviewLimit: UInt64 = 32 * 1_024 * 1_024
    public static let pdfPreviewLimit: UInt64 = 64 * 1_024 * 1_024

    static let vaultHeaderMagic = Data("CVROOT01".utf8)
    static let manifestMagic = Data("CVMAN001".utf8)
    static let objectMagic = Data("CVOBJ001".utf8)
    static let vaultHeaderLength = 28
    static let manifestHeaderLength = 44
    static let objectHeaderLength = 88
}

struct VaultBinaryReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw VaultFormatError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let bytes = try readData(count: MemoryLayout<T>.size)
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            bytes.copyBytes(to: destination)
        }
        return T(bigEndian: value)
    }

    mutating func readUUID() throws -> UUID {
        let bytes = [UInt8](try readData(count: 16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.bigEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }

    mutating func appendUUID(_ value: UUID) {
        var bytes = value.uuid
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}

extension UUID {
    var vaultFileComponent: String {
        uuidString.lowercased()
    }
}
