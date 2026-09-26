import Foundation
import XCTest
@testable import CalcVault

final class EncryptedStreamTests: XCTestCase {
    func testRoundTripsEmptyAndMultiChunkFixtures() throws {
        for size in [0, 1, VaultFormatV1.objectChunkSize, VaultFormatV1.objectChunkSize * 2 + 37] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let plaintext = Data((0..<size).map { UInt8($0 % 251) })
            let source = directory.appendingPathComponent("source.bin")
            let encrypted = directory.appendingPathComponent("encrypted.cvobj")
            let decrypted = directory.appendingPathComponent("decrypted.bin")
            try plaintext.write(to: source)

            let metadata = fixtureMetadata()
            let result = try EncryptedStream().encrypt(
                sourceURL: source,
                destinationURL: encrypted,
                metadata: metadata
            )
            try EncryptedStream().decrypt(
                sourceURL: encrypted,
                destinationURL: decrypted,
                metadata: metadata,
                objectKey: result.objectKey
            )

            XCTAssertEqual(result.plaintextLength, UInt64(size))
            XCTAssertEqual(try Data(contentsOf: decrypted), plaintext)
            let sample = Data(plaintext.prefix(min(32, size)))
            XCTAssertFalse((try Data(contentsOf: encrypted)).range(of: sample) != nil && size >= 32)
        }
    }

    func testWrongKeyCiphertextTamperTruncationAndTrailingBytesFailClosed() throws {
        let fixture = try makeEncryptedFixture(size: VaultFormatV1.objectChunkSize + 19)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let stream = EncryptedStream()

        XCTAssertThrowsError(
            try stream.decrypt(
                sourceURL: fixture.encrypted,
                destinationURL: fixture.directory.appendingPathComponent("wrong-key.bin"),
                metadata: fixture.metadata,
                objectKey: Data(repeating: 0x99, count: 32)
            )
        )

        var tampered = try Data(contentsOf: fixture.encrypted)
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let tamperedURL = fixture.directory.appendingPathComponent("tampered.cvobj")
        try tampered.write(to: tamperedURL)
        XCTAssertThrowsError(
            try stream.decrypt(
                sourceURL: tamperedURL,
                destinationURL: fixture.directory.appendingPathComponent("tampered.bin"),
                metadata: fixture.metadata,
                objectKey: fixture.key
            )
        )

        var truncated = try Data(contentsOf: fixture.encrypted)
        truncated.removeLast(10)
        let truncatedURL = fixture.directory.appendingPathComponent("truncated.cvobj")
        try truncated.write(to: truncatedURL)
        XCTAssertThrowsError(
            try stream.decrypt(
                sourceURL: truncatedURL,
                destinationURL: fixture.directory.appendingPathComponent("truncated.bin"),
                metadata: fixture.metadata,
                objectKey: fixture.key
            )
        )

        var trailing = try Data(contentsOf: fixture.encrypted)
        trailing.append(0xff)
        let trailingURL = fixture.directory.appendingPathComponent("trailing.cvobj")
        try trailing.write(to: trailingURL)
        XCTAssertThrowsError(
            try stream.decrypt(
                sourceURL: trailingURL,
                destinationURL: fixture.directory.appendingPathComponent("trailing.bin"),
                metadata: fixture.metadata,
                objectKey: fixture.key
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .unexpectedTrailingData)
        }
    }

    func testReorderedDuplicatedAndMissingRecordsAreRejected() throws {
        let fixture = try makeEncryptedFixture(size: VaultFormatV1.objectChunkSize * 2 + 9)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.encrypted)
        let records = try splitRecords(original)
        XCTAssertEqual(records.count, 3)

        var reordered = Data(original.prefix(VaultFormatV1.objectHeaderLength))
        reordered.append(records[1])
        reordered.append(records[0])
        reordered.append(records[2])
        try assertRejected(Data(reordered), name: "reordered", fixture: fixture)

        var duplicated = Data(original.prefix(VaultFormatV1.objectHeaderLength))
        duplicated.append(records[0])
        duplicated.append(records[0])
        duplicated.append(records[2])
        try assertRejected(Data(duplicated), name: "duplicated", fixture: fixture)

        var missingFinal = Data(original.prefix(VaultFormatV1.objectHeaderLength))
        missingFinal.append(records[0])
        missingFinal.append(records[1])
        try assertRejected(Data(missingFinal), name: "missing-final", fixture: fixture)
    }

    func testMaliciousRecordLengthAndIdentityMismatchAreRejectedBeforeOutputPublication() throws {
        let fixture = try makeEncryptedFixture(size: 12)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var malicious = try Data(contentsOf: fixture.encrypted)
        var excessive = UInt32.max.bigEndian
        withUnsafeBytes(of: &excessive) { bytes in
            malicious.replaceSubrange(92..<96, with: bytes)
        }
        try assertRejected(malicious, name: "length", fixture: fixture)

        XCTAssertThrowsError(
            try EncryptedStream().decrypt(
                sourceURL: fixture.encrypted,
                destinationURL: fixture.directory.appendingPathComponent("wrong-identity.bin"),
                metadata: EncryptedObjectMetadata(
                    vaultID: fixture.metadata.vaultID,
                    objectID: UUID(),
                    revision: fixture.metadata.revision
                ),
                objectKey: fixture.key
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .identityMismatch)
        }
    }

    func testBoundedMemoryDecryptionAndDiscardValidation() throws {
        let plaintext = Data((0..<(VaultFormatV1.objectChunkSize + 29)).map { UInt8($0 % 239) })
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encrypted = directory.appendingPathComponent("memory.cvobj")
        let metadata = fixtureMetadata()
        let result = try EncryptedStream().encrypt(
            plaintext: plaintext,
            destinationURL: encrypted,
            metadata: metadata
        )

        XCTAssertEqual(
            try EncryptedStream().validate(
                sourceURL: encrypted,
                metadata: metadata,
                objectKey: result.objectKey
            ),
            UInt64(plaintext.count)
        )
        XCTAssertEqual(
            try EncryptedStream().decryptToData(
                sourceURL: encrypted,
                metadata: metadata,
                objectKey: result.objectKey,
                maximumPlaintextLength: UInt64(plaintext.count)
            ),
            plaintext
        )
        XCTAssertThrowsError(
            try EncryptedStream().decryptToData(
                sourceURL: encrypted,
                metadata: metadata,
                objectKey: result.objectKey,
                maximumPlaintextLength: UInt64(plaintext.count - 1)
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .resourceLimitExceeded)
        }
    }

    func testCancellationRemovesPartialEncryptedOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("large.bin")
        let destination = directory.appendingPathComponent("cancelled.cvobj")
        try Data(repeating: 0x5a, count: VaultFormatV1.objectChunkSize * 3).write(to: source)
        let cancellation = StreamCancellationProbe(cancelAtOrAfter: UInt64(VaultFormatV1.objectChunkSize))

        XCTAssertThrowsError(
            try EncryptedStream().encrypt(
                sourceURL: source,
                destinationURL: destination,
                metadata: fixtureMetadata(),
                progress: { completed, _ in cancellation.observe(completed) },
                shouldCancel: { cancellation.isCancelled() }
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .operationCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func assertRejected(
        _ data: Data,
        name: String,
        fixture: EncryptedFixture
    ) throws {
        let source = fixture.directory.appendingPathComponent("\(name).cvobj")
        let output = fixture.directory.appendingPathComponent("\(name).bin")
        try data.write(to: source)
        XCTAssertThrowsError(
            try EncryptedStream().decrypt(
                sourceURL: source,
                destinationURL: output,
                metadata: fixture.metadata,
                objectKey: fixture.key
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func splitRecords(_ data: Data) throws -> [Data] {
        var records: [Data] = []
        var offset = VaultFormatV1.objectHeaderLength
        while offset < data.count {
            guard data.count - offset >= 8 else { throw VaultFormatError.truncated }
            let lengthBytes = data.subdata(in: (offset + 4)..<(offset + 8))
            var encoded: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &encoded) { lengthBytes.copyBytes(to: $0) }
            let length = Int(UInt32(bigEndian: encoded))
            guard data.count - offset >= 8 + length else { throw VaultFormatError.truncated }
            records.append(data.subdata(in: offset..<(offset + 8 + length)))
            offset += 8 + length
        }
        return records
    }

    private func makeEncryptedFixture(size: Int) throws -> EncryptedFixture {
        let directory = try makeTemporaryDirectory()
        let source = directory.appendingPathComponent("source.bin")
        let encrypted = directory.appendingPathComponent("object.cvobj")
        try Data((0..<size).map { UInt8(($0 * 7) % 251) }).write(to: source)
        let metadata = fixtureMetadata()
        let result = try EncryptedStream().encrypt(
            sourceURL: source,
            destinationURL: encrypted,
            metadata: metadata
        )
        return EncryptedFixture(
            directory: directory,
            encrypted: encrypted,
            metadata: metadata,
            key: result.objectKey
        )
    }

    private func fixtureMetadata() -> EncryptedObjectMetadata {
        EncryptedObjectMetadata(
            vaultID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            objectID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            revision: 1
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-EncryptedStream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private struct EncryptedFixture {
    let directory: URL
    let encrypted: URL
    let metadata: EncryptedObjectMetadata
    let key: Data
}

private final class StreamCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: UInt64
    private var cancelled = false

    init(cancelAtOrAfter threshold: UInt64) {
        self.threshold = threshold
    }

    func observe(_ completed: UInt64) {
        lock.lock()
        if completed >= threshold { cancelled = true }
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
