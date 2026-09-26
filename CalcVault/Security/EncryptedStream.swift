import Foundation
import Sodium

public struct EncryptedObjectMetadata: Equatable, Sendable {
    public let vaultID: UUID
    public let objectID: UUID
    public let revision: UInt64

    public init(vaultID: UUID, objectID: UUID, revision: UInt64) {
        self.vaultID = vaultID
        self.objectID = objectID
        self.revision = revision
    }
}

public struct EncryptedObjectResult: Equatable, Sendable {
    public let objectKey: Data
    public let plaintextLength: UInt64

    public init(objectKey: Data, plaintextLength: UInt64) {
        self.objectKey = objectKey
        self.plaintextLength = plaintextLength
    }
}

public struct EncryptedStream: Sendable {
    public typealias ProgressHandler = @Sendable (_ completedBytes: UInt64, _ totalBytes: UInt64) -> Void
    public typealias CancellationCheck = @Sendable () -> Bool

    private let keyHierarchy = VaultKeyHierarchy()

    public init() {}

    public func encrypt(
        sourceURL: URL,
        destinationURL: URL,
        metadata: EncryptedObjectMetadata,
        progress: @escaping ProgressHandler = { _, _ in },
        shouldCancel: @escaping CancellationCheck = { false }
    ) throws -> EncryptedObjectResult {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw VaultFormatError.ioFailure("The source size is unavailable.")
        }
        let plaintextLength = fileSize.uint64Value
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        return try encryptPayload(
            plaintextLength: plaintextLength,
            destinationURL: destinationURL,
            metadata: metadata,
            progress: progress,
            shouldCancel: shouldCancel
        ) {
            try input.read(upToCount: VaultFormatV1.objectChunkSize) ?? Data()
        }
    }

    public func encrypt(
        plaintext: Data,
        destinationURL: URL,
        metadata: EncryptedObjectMetadata,
        progress: @escaping ProgressHandler = { _, _ in },
        shouldCancel: @escaping CancellationCheck = { false }
    ) throws -> EncryptedObjectResult {
        var offset = 0
        return try encryptPayload(
            plaintextLength: UInt64(plaintext.count),
            destinationURL: destinationURL,
            metadata: metadata,
            progress: progress,
            shouldCancel: shouldCancel
        ) {
            guard offset < plaintext.count else { return Data() }
            let end = min(offset + VaultFormatV1.objectChunkSize, plaintext.count)
            defer { offset = end }
            return plaintext.subdata(in: offset..<end)
        }
    }

    private func encryptPayload(
        plaintextLength: UInt64,
        destinationURL: URL,
        metadata: EncryptedObjectMetadata,
        progress: @escaping ProgressHandler,
        shouldCancel: @escaping CancellationCheck,
        readChunk: () throws -> Data
    ) throws -> EncryptedObjectResult {
        guard !shouldCancel() else { throw VaultFormatError.operationCancelled }
        guard metadata.revision > 0 else { throw VaultFormatError.invalidObject }
        guard plaintextLength <= VaultFormatV1.objectPlaintextLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw VaultFormatError.ioFailure("The staging destination already exists.")
        }

        let objectKey = try keyHierarchy.generateObjectKey()
        let algorithm = Sodium().secretStream.xchacha20poly1305
        let authenticationBytes = SecretStream.XChaCha20Poly1305.ABytes
        guard SecretStream.XChaCha20Poly1305.HeaderBytes == 24 else {
            throw VaultFormatError.unsupportedVersion(Int(VaultFormatV1.version))
        }
        guard let stream = algorithm.initPush(secretKey: Array(objectKey)) else {
            throw VaultFormatError.authenticationFailed
        }
        let header = makeHeader(
            metadata: metadata,
            plaintextLength: plaintextLength,
            streamHeader: Data(stream.header())
        )
        guard header.count == VaultFormatV1.objectHeaderLength else {
            throw VaultFormatError.malformedHeader
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw VaultFormatError.ioFailure("The encrypted staging file could not be created.")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        var succeeded = false
        defer {
            try? output.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        do {
            try output.write(contentsOf: header)
            var sequence: UInt32 = 0
            var totalRead: UInt64 = 0
            progress(0, plaintextLength)
            var current = try readChunk()
            repeat {
                guard !shouldCancel() else { throw VaultFormatError.operationCancelled }
                let next = try readChunk()
                let isFinal = next.isEmpty
                guard current.count <= VaultFormatV1.objectChunkSize else {
                    throw VaultFormatError.resourceLimitExceeded
                }
                let ciphertextLength = current.count + authenticationBytes
                guard ciphertextLength <= Int(UInt32.max) else {
                    throw VaultFormatError.resourceLimitExceeded
                }
                var recordHeader = Data()
                recordHeader.appendBigEndian(sequence)
                recordHeader.appendBigEndian(UInt32(ciphertextLength))
                var associatedData = header
                associatedData.append(recordHeader)
                guard let ciphertext = stream.push(
                    message: Array(current),
                    tag: isFinal ? .FINAL : .MESSAGE,
                    ad: Array(associatedData)
                ) else {
                    throw VaultFormatError.authenticationFailed
                }
                try output.write(contentsOf: recordHeader)
                try output.write(contentsOf: Data(ciphertext))
                totalRead += UInt64(current.count)
                progress(totalRead, plaintextLength)
                if isFinal { break }
                guard sequence < UInt32.max else {
                    throw VaultFormatError.resourceLimitExceeded
                }
                sequence += 1
                current = next
            } while true

            guard totalRead == plaintextLength else {
                throw VaultFormatError.ioFailure("The source changed while it was being encrypted.")
            }
            try output.synchronize()
            succeeded = true
            return EncryptedObjectResult(objectKey: objectKey, plaintextLength: plaintextLength)
        } catch let error as VaultFormatError {
            throw error
        } catch {
            throw VaultFormatError.ioFailure(error.localizedDescription)
        }
    }

    public func decrypt(
        sourceURL: URL,
        destinationURL: URL,
        metadata: EncryptedObjectMetadata,
        objectKey: Data,
        progress: @escaping ProgressHandler = { _, _ in },
        shouldCancel: @escaping CancellationCheck = { false }
    ) throws {
        guard objectKey.count == VaultKeyHierarchy.objectKeyBytes,
              metadata.revision > 0 else {
            throw VaultFormatError.invalidObject
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw VaultFormatError.ioFailure("The plaintext destination already exists.")
        }

        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw VaultFormatError.ioFailure("The plaintext staging file could not be created.")
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        var succeeded = false
        defer {
            try? output.close()
            if !succeeded {
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        do {
            _ = try decryptPayload(
                sourceURL: sourceURL,
                metadata: metadata,
                objectKey: objectKey,
                maximumPlaintextLength: nil,
                progress: progress,
                shouldCancel: shouldCancel
            ) { chunk in
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            succeeded = true
        } catch let error as VaultFormatError {
            throw error
        } catch {
            throw VaultFormatError.ioFailure(error.localizedDescription)
        }
    }

    public func decryptToData(
        sourceURL: URL,
        metadata: EncryptedObjectMetadata,
        objectKey: Data,
        maximumPlaintextLength: UInt64,
        shouldCancel: @escaping CancellationCheck = { false }
    ) throws -> Data {
        var plaintext = Data()
        let length = try decryptPayload(
            sourceURL: sourceURL,
            metadata: metadata,
            objectKey: objectKey,
            maximumPlaintextLength: maximumPlaintextLength,
            progress: { _, _ in },
            shouldCancel: shouldCancel
        ) { chunk in
            plaintext.append(chunk)
        }
        guard UInt64(plaintext.count) == length else {
            throw VaultFormatError.invalidObject
        }
        return plaintext
    }

    @discardableResult
    public func validate(
        sourceURL: URL,
        metadata: EncryptedObjectMetadata,
        objectKey: Data,
        shouldCancel: @escaping CancellationCheck = { false }
    ) throws -> UInt64 {
        try decryptPayload(
            sourceURL: sourceURL,
            metadata: metadata,
            objectKey: objectKey,
            maximumPlaintextLength: nil,
            progress: { _, _ in },
            shouldCancel: shouldCancel,
            consume: { _ in }
        )
    }

    private func decryptPayload(
        sourceURL: URL,
        metadata: EncryptedObjectMetadata,
        objectKey: Data,
        maximumPlaintextLength: UInt64?,
        progress: @escaping ProgressHandler,
        shouldCancel: @escaping CancellationCheck,
        consume: (Data) throws -> Void
    ) throws -> UInt64 {
        guard objectKey.count == VaultKeyHierarchy.objectKeyBytes,
              metadata.revision > 0 else {
            throw VaultFormatError.invalidObject
        }
        guard !shouldCancel() else { throw VaultFormatError.operationCancelled }

        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        do {
            let header = try input.readExactly(count: VaultFormatV1.objectHeaderLength)
            let parsed = try parseHeader(header, expected: metadata)
            if let maximumPlaintextLength,
               parsed.plaintextLength > maximumPlaintextLength {
                throw VaultFormatError.resourceLimitExceeded
            }
            let algorithm = Sodium().secretStream.xchacha20poly1305
            let authenticationBytes = SecretStream.XChaCha20Poly1305.ABytes
            guard let stream = algorithm.initPull(
                secretKey: Array(objectKey),
                header: Array(parsed.streamHeader)
            ) else {
                throw VaultFormatError.authenticationFailed
            }

            progress(0, parsed.plaintextLength)
            var expectedSequence: UInt32 = 0
            var totalWritten: UInt64 = 0
            while true {
                guard !shouldCancel() else { throw VaultFormatError.operationCancelled }
                let recordHeader: Data
                do {
                    recordHeader = try input.readExactly(count: 8)
                } catch VaultFormatError.truncated {
                    throw VaultFormatError.missingFinalTag
                }
                var recordReader = VaultBinaryReader(recordHeader)
                let sequence: UInt32 = try recordReader.readInteger()
                let ciphertextLengthValue: UInt32 = try recordReader.readInteger()
                let ciphertextLength = Int(ciphertextLengthValue)
                guard sequence == expectedSequence,
                      ciphertextLength >= authenticationBytes,
                      ciphertextLength <= VaultFormatV1.objectChunkSize + authenticationBytes else {
                    throw VaultFormatError.invalidObject
                }

                let ciphertext = try input.readExactly(count: ciphertextLength)
                var associatedData = header
                associatedData.append(recordHeader)
                guard let (message, tag) = stream.pull(
                    cipherText: Array(ciphertext),
                    ad: Array(associatedData)
                ) else {
                    throw VaultFormatError.authenticationFailed
                }

                let messageData = Data(message)
                let proposedTotal = totalWritten + UInt64(messageData.count)
                guard proposedTotal <= parsed.plaintextLength else {
                    throw VaultFormatError.invalidObject
                }
                switch tag {
                case .MESSAGE:
                    guard messageData.count == VaultFormatV1.objectChunkSize,
                          proposedTotal < parsed.plaintextLength else {
                        throw VaultFormatError.invalidObject
                    }
                case .FINAL:
                    guard proposedTotal == parsed.plaintextLength else {
                        throw VaultFormatError.invalidObject
                    }
                    try consume(messageData)
                    let trailing = try input.read(upToCount: 1) ?? Data()
                    guard trailing.isEmpty else {
                        throw VaultFormatError.unexpectedTrailingData
                    }
                    progress(proposedTotal, parsed.plaintextLength)
                    return proposedTotal
                case .PUSH, .REKEY:
                    throw VaultFormatError.invalidObject
                }

                try consume(messageData)
                totalWritten = proposedTotal
                progress(totalWritten, parsed.plaintextLength)
                guard expectedSequence < UInt32.max else {
                    throw VaultFormatError.resourceLimitExceeded
                }
                expectedSequence += 1
            }
        } catch let error as VaultFormatError {
            throw error
        } catch {
            throw VaultFormatError.ioFailure(error.localizedDescription)
        }
    }

    private func makeHeader(
        metadata: EncryptedObjectMetadata,
        plaintextLength: UInt64,
        streamHeader: Data
    ) -> Data {
        var data = Data()
        data.append(VaultFormatV1.objectMagic)
        data.appendBigEndian(VaultFormatV1.version)
        data.appendBigEndian(UInt16(0))
        data.appendUUID(metadata.vaultID)
        data.appendUUID(metadata.objectID)
        data.appendBigEndian(metadata.revision)
        data.appendBigEndian(plaintextLength)
        data.appendBigEndian(UInt32(VaultFormatV1.objectChunkSize))
        data.append(streamHeader)
        return data
    }

    private func parseHeader(
        _ data: Data,
        expected: EncryptedObjectMetadata
    ) throws -> (plaintextLength: UInt64, streamHeader: Data) {
        guard data.count == VaultFormatV1.objectHeaderLength else {
            throw VaultFormatError.malformedHeader
        }
        var reader = VaultBinaryReader(data)
        guard try reader.readData(count: 8) == VaultFormatV1.objectMagic else {
            throw VaultFormatError.malformedHeader
        }
        let version: UInt16 = try reader.readInteger()
        guard version == VaultFormatV1.version else {
            throw VaultFormatError.unsupportedVersion(Int(version))
        }
        let reserved: UInt16 = try reader.readInteger()
        guard reserved == 0 else { throw VaultFormatError.malformedHeader }
        let vaultID = try reader.readUUID()
        let objectID = try reader.readUUID()
        let revision: UInt64 = try reader.readInteger()
        let plaintextLength: UInt64 = try reader.readInteger()
        let chunkSize: UInt32 = try reader.readInteger()
        let streamHeader = try reader.readData(count: 24)
        guard vaultID == expected.vaultID,
              objectID == expected.objectID,
              revision == expected.revision else {
            throw VaultFormatError.identityMismatch
        }
        guard revision > 0,
              plaintextLength <= VaultFormatV1.objectPlaintextLimit,
              chunkSize == UInt32(VaultFormatV1.objectChunkSize),
              reader.remaining == 0 else {
            throw VaultFormatError.invalidObject
        }
        return (plaintextLength, streamHeader)
    }
}

private extension FileHandle {
    func readExactly(count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let part = try read(upToCount: count - result.count) ?? Data()
            guard !part.isEmpty else { throw VaultFormatError.truncated }
            result.append(part)
        }
        return result
    }
}
