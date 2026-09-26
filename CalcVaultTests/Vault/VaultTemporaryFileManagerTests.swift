import Foundation
import XCTest
@testable import CalcVault

final class VaultTemporaryFileManagerTests: XCTestCase {
    func testCreatesRandomOwnedDestinationAndRemovesIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let manager = try VaultTemporaryFileManager(rootDirectory: fixture.root)
        let url = try manager.makeDestination(preferredExtension: "TXT")
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(url.deletingLastPathComponent(), fixture.root)
        try manager.prepareEmptyFile(at: url)
        try Data("disposable plaintext".utf8).write(to: url)
        try manager.finalizeFile(at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        manager.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInitializationCleansOnlyPriorOwnedChildren() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let prior = fixture.root.appendingPathComponent("prior.tmp")
        let sibling = fixture.parent.appendingPathComponent("must-survive.txt")
        try Data("old temporary plaintext".utf8).write(to: prior)
        try Data("outside manager ownership".utf8).write(to: sibling)

        _ = try VaultTemporaryFileManager(rootDirectory: fixture.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prior.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

    private func makeFixture() throws -> (parent: URL, root: URL) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-TemporaryManager-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("CalcVaultTransient", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        return (parent, root)
    }
}
