import Foundation
import XCTest
@testable import CalcVault

final class VaultFileStagerTests: XCTestCase {
    func testStagesDisposableFileAndPreservesSource() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let manager = try VaultTemporaryFileManager(rootDirectory: fixture.transient)
        let source = fixture.parent.appendingPathComponent("source.txt")
        let plaintext = Data("disposable picker fixture".utf8)
        try plaintext.write(to: source)

        let staged = try VaultFileStager(temporaryFiles: manager).stage(
            sourceURL: source,
            preferredExtension: "txt"
        )
        XCTAssertEqual(try Data(contentsOf: staged), plaintext)
        XCTAssertEqual(try Data(contentsOf: source), plaintext)
        manager.remove(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testCancelledStagingRemovesPartialCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let manager = try VaultTemporaryFileManager(rootDirectory: fixture.transient)
        let source = fixture.parent.appendingPathComponent("large.bin")
        try Data(repeating: 0xcc, count: VaultFormatV1.objectChunkSize * 3).write(to: source)
        let cancellation = VaultOperationCancellation()

        XCTAssertThrowsError(
            try VaultFileStager(temporaryFiles: manager).stage(
                sourceURL: source,
                preferredExtension: "bin",
                progress: { completed, _ in
                    if completed >= UInt64(VaultFormatV1.objectChunkSize) {
                        cancellation.cancel()
                    }
                },
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .operationCancelled)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: fixture.transient, includingPropertiesForKeys: nil).count,
            0
        )
    }

    private func makeFixture() throws -> (parent: URL, transient: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-Stager-\(UUID().uuidString)", isDirectory: true)
        let transient = parent.appendingPathComponent("CalcVaultTransient", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return (parent, transient)
    }
}
