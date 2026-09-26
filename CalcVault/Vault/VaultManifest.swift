import Foundation
import Sodium

public enum VaultItemKind: String, Codable, CaseIterable, Sendable {
    case file
    case folder
    case note
    case photo
    case video
    case thumbnail
}

public struct VaultManifestItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let kind: VaultItemKind
    public let displayName: String
    public let mediaType: String?
    public let byteCount: UInt64
    public let createdAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64
    public let revision: UInt64
    public let objectFileName: String?
    public let objectKey: Data?
    public let thumbnailID: UUID?

    public init(
        id: UUID,
        parentID: UUID? = nil,
        kind: VaultItemKind,
        displayName: String,
        mediaType: String? = nil,
        byteCount: UInt64 = 0,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        revision: UInt64,
        objectFileName: String? = nil,
        objectKey: Data? = nil,
        thumbnailID: UUID? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.revision = revision
        self.objectFileName = objectFileName
        self.objectKey = objectKey
        self.thumbnailID = thumbnailID
    }
}

public struct VaultManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let vaultID: UUID
    public let generation: UInt64
    public let createdAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64
    public let items: [VaultManifestItem]

    public init(
        formatVersion: Int = Int(VaultFormatV1.version),
        vaultID: UUID,
        generation: UInt64,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        items: [VaultManifestItem]
    ) {
        self.formatVersion = formatVersion
        self.vaultID = vaultID
        self.generation = generation
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.items = items
    }
}

public struct VaultManifestCodec: Sendable {
    private let keyHierarchy = VaultKeyHierarchy()

    public init() {}

    public func seal(_ manifest: VaultManifest, rootKey: Data) throws -> Data {
        try validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(manifest)
        guard plaintext.count <= VaultFormatV1.manifestPlaintextLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }

        let sodium = Sodium()
        let aead = sodium.aead.xchacha20poly1305ietf
        let ciphertextLength = plaintext.count + aead.NonceBytes + aead.ABytes
        var header = makeHeader(
            vaultID: manifest.vaultID,
            generation: manifest.generation,
            ciphertextLength: UInt64(ciphertextLength)
        )
        let key = try keyHierarchy.manifestKey(from: rootKey)
        guard let ciphertext: [UInt8] = aead.encrypt(
            message: Array(plaintext),
            secretKey: Array(key),
            additionalData: Array(header)
        ) else {
            throw VaultFormatError.authenticationFailed
        }
        guard ciphertext.count == ciphertextLength else {
            throw VaultFormatError.invalidManifest
        }
        header.append(contentsOf: ciphertext)
        return header
    }

    public func open(
        _ sealedManifest: Data,
        rootKey: Data,
        expectedVaultID: UUID
    ) throws -> VaultManifest {
        guard sealedManifest.count >= VaultFormatV1.manifestHeaderLength else {
            throw VaultFormatError.truncated
        }
        let header = sealedManifest.prefix(VaultFormatV1.manifestHeaderLength)
        var reader = VaultBinaryReader(Data(header))
        guard try reader.readData(count: 8) == VaultFormatV1.manifestMagic else {
            throw VaultFormatError.malformedHeader
        }
        let version: UInt16 = try reader.readInteger()
        guard version == VaultFormatV1.version else {
            throw VaultFormatError.unsupportedVersion(Int(version))
        }
        let reserved: UInt16 = try reader.readInteger()
        guard reserved == 0 else { throw VaultFormatError.malformedHeader }
        let vaultID = try reader.readUUID()
        guard vaultID == expectedVaultID else { throw VaultFormatError.identityMismatch }
        let generation: UInt64 = try reader.readInteger()
        let ciphertextLength: UInt64 = try reader.readInteger()
        guard generation > 0,
              ciphertextLength <= UInt64(VaultFormatV1.manifestPlaintextLimit + 64),
              ciphertextLength <= UInt64(Int.max),
              sealedManifest.count == VaultFormatV1.manifestHeaderLength + Int(ciphertextLength) else {
            throw VaultFormatError.invalidManifest
        }

        let key = try keyHierarchy.manifestKey(from: rootKey)
        let ciphertext = sealedManifest.suffix(Int(ciphertextLength))
        guard let plaintext = Sodium().aead.xchacha20poly1305ietf.decrypt(
            nonceAndAuthenticatedCipherText: Array(ciphertext),
            secretKey: Array(key),
            additionalData: Array(header)
        ) else {
            throw VaultFormatError.authenticationFailed
        }
        guard plaintext.count <= VaultFormatV1.manifestPlaintextLimit,
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: Data(plaintext)) else {
            throw VaultFormatError.invalidManifest
        }
        guard manifest.vaultID == vaultID, manifest.generation == generation else {
            throw VaultFormatError.identityMismatch
        }
        try validate(manifest)
        return manifest
    }

    public func validate(_ manifest: VaultManifest) throws {
        guard manifest.formatVersion == Int(VaultFormatV1.version) else {
            throw VaultFormatError.unsupportedVersion(manifest.formatVersion)
        }
        guard manifest.generation > 0,
              manifest.createdAtMilliseconds >= 0,
              manifest.updatedAtMilliseconds >= manifest.createdAtMilliseconds,
              manifest.items.count <= VaultFormatV1.itemCountLimit else {
            throw VaultFormatError.invalidManifest
        }

        let itemIDs = Set(manifest.items.map(\.id))
        let objectNames = manifest.items.compactMap(\.objectFileName)
        guard itemIDs.count == manifest.items.count,
              Set(objectNames).count == objectNames.count else {
            throw VaultFormatError.invalidManifest
        }

        let itemByID = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        for item in manifest.items {
            guard !item.displayName.isEmpty,
                  item.displayName.utf8.count <= VaultFormatV1.displayNameByteLimit,
                  (item.mediaType?.utf8.count ?? 0) <= VaultFormatV1.mediaTypeByteLimit,
                  item.byteCount <= VaultFormatV1.objectPlaintextLimit,
                  item.createdAtMilliseconds >= 0,
                  item.updatedAtMilliseconds >= item.createdAtMilliseconds,
                  item.revision > 0,
                  item.parentID != item.id,
                  item.thumbnailID != item.id else {
                throw VaultFormatError.invalidManifest
            }
            if let parentID = item.parentID {
                guard itemByID[parentID]?.kind == .folder else {
                    throw VaultFormatError.invalidManifest
                }
            }

            if item.kind == .folder {
                guard item.objectFileName == nil,
                      item.objectKey == nil,
                      item.byteCount == 0,
                      item.mediaType == nil else {
                    throw VaultFormatError.invalidManifest
                }
            } else {
                guard let name = item.objectFileName,
                      isValidObjectFileName(name),
                      item.objectKey?.count == VaultKeyHierarchy.objectKeyBytes else {
                    throw VaultFormatError.invalidManifest
                }
            }
            if let thumbnailID = item.thumbnailID {
                guard itemByID[thumbnailID]?.kind == .thumbnail else {
                    throw VaultFormatError.invalidManifest
                }
            }
        }
        try validateNoParentCycles(manifest.items, itemByID: itemByID)
    }

    private func makeHeader(
        vaultID: UUID,
        generation: UInt64,
        ciphertextLength: UInt64
    ) -> Data {
        var data = Data()
        data.append(VaultFormatV1.manifestMagic)
        data.appendBigEndian(VaultFormatV1.version)
        data.appendBigEndian(UInt16(0))
        data.appendUUID(vaultID)
        data.appendBigEndian(generation)
        data.appendBigEndian(ciphertextLength)
        return data
    }

    private func isValidObjectFileName(_ name: String) -> Bool {
        guard name == name.lowercased(), name.hasSuffix(".cvobj") else { return false }
        let stem = String(name.dropLast(".cvobj".count))
        guard let identifier = UUID(uuidString: stem) else { return false }
        return identifier.vaultFileComponent == stem && !name.contains("/") && !name.contains("\\")
    }

    private func validateNoParentCycles(
        _ items: [VaultManifestItem],
        itemByID: [UUID: VaultManifestItem]
    ) throws {
        for item in items {
            var visited: Set<UUID> = [item.id]
            var parentID = item.parentID
            while let current = parentID {
                guard visited.insert(current).inserted else {
                    throw VaultFormatError.invalidManifest
                }
                parentID = itemByID[current]?.parentID
            }
        }
    }
}
