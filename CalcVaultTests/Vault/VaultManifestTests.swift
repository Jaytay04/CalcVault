import Foundation
import XCTest
@testable import CalcVault

final class VaultManifestTests: XCTestCase {
    func testManifestRoundTripEncryptsNamesAndObjectKeys() throws {
        let fixture = makeFixture()
        let sealed = try VaultManifestCodec().seal(fixture.manifest, rootKey: fixture.rootKey)

        XCTAssertFalse(sealed.range(of: Data("private-note.txt".utf8)) != nil)
        XCTAssertFalse(sealed.range(of: fixture.objectKey) != nil)
        XCTAssertEqual(
            try VaultManifestCodec().open(
                sealed,
                rootKey: fixture.rootKey,
                expectedVaultID: fixture.manifest.vaultID
            ),
            fixture.manifest
        )
    }

    func testWrongKeyTamperAndWrongVaultFailClosed() throws {
        let fixture = makeFixture()
        let codec = VaultManifestCodec()
        let sealed = try codec.seal(fixture.manifest, rootKey: fixture.rootKey)

        XCTAssertThrowsError(
            try codec.open(sealed, rootKey: Data(repeating: 0x44, count: 32), expectedVaultID: fixture.manifest.vaultID)
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .authenticationFailed)
        }

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(
            try codec.open(tampered, rootKey: fixture.rootKey, expectedVaultID: fixture.manifest.vaultID)
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .authenticationFailed)
        }

        XCTAssertThrowsError(
            try codec.open(sealed, rootKey: fixture.rootKey, expectedVaultID: UUID())
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .identityMismatch)
        }
    }

    func testMaliciousLengthAndPlaintextMetadataBoundsAreRejected() throws {
        let fixture = makeFixture()
        let codec = VaultManifestCodec()
        var sealed = try codec.seal(fixture.manifest, rootKey: fixture.rootKey)
        sealed.replaceSubrange(36..<44, with: Data(repeating: 0xff, count: 8))
        XCTAssertThrowsError(
            try codec.open(sealed, rootKey: fixture.rootKey, expectedVaultID: fixture.manifest.vaultID)
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .invalidManifest)
        }

        let oversized = VaultManifestItem(
            id: UUID(),
            kind: .note,
            displayName: String(repeating: "x", count: VaultFormatV1.displayNameByteLimit + 1),
            byteCount: 0,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            revision: 1,
            objectFileName: "\(UUID().vaultFileComponent).cvobj",
            objectKey: Data(repeating: 0x33, count: 32)
        )
        let invalid = VaultManifest(
            vaultID: fixture.manifest.vaultID,
            generation: 1,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            items: [oversized]
        )
        XCTAssertThrowsError(try codec.seal(invalid, rootKey: fixture.rootKey)) { error in
            XCTAssertEqual(error as? VaultFormatError, .invalidManifest)
        }
    }

    func testPurposeSeparatedManifestKeyIsDeterministicAndBounded() throws {
        let hierarchy = VaultKeyHierarchy()
        let root = Data((0..<32).map { UInt8($0) })
        let first = try hierarchy.manifestKey(from: root)
        let second = try hierarchy.manifestKey(from: root)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, root)
        XCTAssertNotEqual(try hierarchy.generateObjectKey(), try hierarchy.generateObjectKey())
        XCTAssertThrowsError(try hierarchy.manifestKey(from: Data(repeating: 0, count: 31)))
    }

    private func makeFixture() -> (manifest: VaultManifest, rootKey: Data, objectKey: Data) {
        let vaultID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let objectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let objectKey = Data((0..<32).map { UInt8($0 + 1) })
        let item = VaultManifestItem(
            id: objectID,
            kind: .note,
            displayName: "private-note.txt",
            mediaType: "text/plain",
            byteCount: 17,
            createdAtMilliseconds: 1_700_000_000_000,
            updatedAtMilliseconds: 1_700_000_000_001,
            revision: 1,
            objectFileName: "\(objectID.vaultFileComponent).cvobj",
            objectKey: objectKey
        )
        return (
            VaultManifest(
                vaultID: vaultID,
                generation: 1,
                createdAtMilliseconds: 1_700_000_000_000,
                updatedAtMilliseconds: 1_700_000_000_001,
                items: [item]
            ),
            Data(repeating: 0x11, count: 32),
            objectKey
        )
    }
}
