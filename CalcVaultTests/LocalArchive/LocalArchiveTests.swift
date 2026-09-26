import Foundation
import XCTest
@testable import CalcVault

final class LocalArchiveTests: XCTestCase {
    private var fixtureDirectory: URL!
    private var defaultsSuites: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsSuites = []
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-LocalArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        for suiteName in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        try super.tearDownWithError()
    }

    func testListsDisposableSyntheticArchiveWithoutExtracting() throws {
        let url = fixtureDirectory.appendingPathComponent("fixture.tar")
        try writeTar(
            entries: [
                SyntheticTarEntry(name: "notes/readme.txt", payload: Data("fixture".utf8)),
                SyntheticTarEntry(name: "photos", payload: Data(), typeFlag: 53)
            ],
            to: url
        )

        let entries = try ReadOnlyTARListing().list(at: url)
        XCTAssertEqual(entries.map(\.path), ["notes/readme.txt", "photos"])
        XCTAssertEqual(entries[0].kind, .file)
        XCTAssertEqual(entries[1].kind, .directory)
        XCTAssertEqual(entries[0].size, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("notes").path))
    }

    func testRejectsTraversalPath() throws {
        let url = fixtureDirectory.appendingPathComponent("traversal.tar")
        try writeTar(entries: [SyntheticTarEntry(name: "../outside.txt", payload: Data())], to: url)

        XCTAssertThrowsError(try ReadOnlyTARListing().list(at: url)) { error in
            guard case LocalArchiveError.unsafePath = error else {
                return XCTFail("Expected unsafe path, got \(error)")
            }
        }
    }

    func testRejectsUnsupportedSpecialEntry() throws {
        let url = fixtureDirectory.appendingPathComponent("link.tar")
        try writeTar(entries: [SyntheticTarEntry(name: "link", payload: Data(), typeFlag: 50)], to: url)

        XCTAssertThrowsError(try ReadOnlyTARListing().list(at: url)) { error in
            guard case LocalArchiveError.malformedArchive(let reason) = error else {
                return XCTFail("Expected unsupported special entry, got \(error)")
            }
            XCTAssertTrue(reason.contains("special"))
        }
    }

    func testRejectsMalformedChecksumAndTruncatedArchive() throws {
        let validURL = fixtureDirectory.appendingPathComponent("valid.tar")
        try writeTar(entries: [SyntheticTarEntry(name: "sample.txt", payload: Data("x".utf8))], to: validURL)
        var bytes = try Data(contentsOf: validURL)
        bytes[0] ^= 0x01
        let checksumURL = fixtureDirectory.appendingPathComponent("bad-checksum.tar")
        try bytes.write(to: checksumURL, options: .atomic)

        XCTAssertThrowsError(try ReadOnlyTARListing().list(at: checksumURL)) { error in
            guard case LocalArchiveError.malformedArchive(let reason) = error else {
                return XCTFail("Expected malformed archive, got \(error)")
            }
            XCTAssertTrue(reason.contains("checksum"))
        }

        let truncatedURL = fixtureDirectory.appendingPathComponent("truncated.tar")
        try Data(repeating: 0, count: 17).write(to: truncatedURL, options: .atomic)
        XCTAssertThrowsError(try ReadOnlyTARListing().list(at: truncatedURL))
    }

    func testEnforcesDisposableFixtureResourceBounds() throws {
        let entryLimitURL = fixtureDirectory.appendingPathComponent("entry-limit.tar")
        try writeTar(
            entries: [
                SyntheticTarEntry(name: "one.txt", payload: Data()),
                SyntheticTarEntry(name: "two.txt", payload: Data())
            ],
            to: entryLimitURL
        )
        let entryLimits = TARListingLimits(maxEntries: 1, maxEntryBytes: 16, maxScannedBytes: 4_096)
        XCTAssertThrowsError(try ReadOnlyTARListing(limits: entryLimits).list(at: entryLimitURL)) { error in
            XCTAssertEqual(error as? LocalArchiveError, .entryLimitExceeded)
        }

        let sizeLimitURL = fixtureDirectory.appendingPathComponent("size-limit.tar")
        try writeTar(
            entries: [SyntheticTarEntry(name: "large.txt", payload: Data(repeating: 1, count: 2))],
            to: sizeLimitURL
        )
        let sizeLimits = TARListingLimits(maxEntries: 2, maxEntryBytes: 1, maxScannedBytes: 4_096)
        XCTAssertThrowsError(try ReadOnlyTARListing(limits: sizeLimits).list(at: sizeLimitURL)) { error in
            guard case LocalArchiveError.entryTooLarge = error else {
                return XCTFail("Expected entry size limit, got \(error)")
            }
        }
    }

    func testMissingBookmarkFailsWithoutCreatingArchive() throws {
        let defaults = try makeIsolatedDefaults()
        let key = "missing-bookmark"
        let storage = UserDefaultsArchiveBookmarkStorage(defaults: defaults, key: key)
        let source = LocalArchiveSource(bookmarkStorage: storage)

        XCTAssertThrowsError(try source.listCurrentArchive()) { error in
            XCTAssertEqual(error as? LocalArchiveError, .bookmarkMissing)
        }
        XCTAssertNil(storage.readBookmarkData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureDirectory.appendingPathComponent("archive.tar").path))
    }

    func testInvalidSelectionDoesNotReplaceExistingReference() throws {
        let originalBookmark = Data("existing-valid-reference".utf8)
        let storage = InMemoryBookmarkStorage(bookmark: originalBookmark)
        let source = LocalArchiveSource(bookmarkStorage: storage)
        let invalidURL = fixtureDirectory.appendingPathComponent("invalid.tar")
        try Data("not a TAR".utf8).write(to: invalidURL, options: .atomic)

        XCTAssertThrowsError(try source.selectArchive(at: invalidURL))
        XCTAssertEqual(storage.readBookmarkData(), originalBookmark)
    }

    func testRemovedAuthoritativeArchiveFailsInsteadOfFallingBack() throws {
        let archiveURL = fixtureDirectory.appendingPathComponent("authoritative.tar")
        try writeTar(entries: [SyntheticTarEntry(name: "one.txt", payload: Data("one".utf8))], to: archiveURL)

        let defaults = try makeIsolatedDefaults()
        let storage = UserDefaultsArchiveBookmarkStorage(defaults: defaults, key: "authoritative-bookmark")
        let source = LocalArchiveSource(bookmarkStorage: storage)
        try source.selectArchive(at: archiveURL)
        try FileManager.default.removeItem(at: archiveURL)

        XCTAssertThrowsError(try source.listCurrentArchive()) { error in
            guard let archiveError = error as? LocalArchiveError else {
                return XCTFail("Expected an archive error, got \(error)")
            }
            switch archiveError {
            case .archiveMissing, .bookmarkStale, .bookmarkInvalid:
                // Bookmark resolution differs by OS version after the target is
                // removed. Every accepted result is a visible failure; none creates
                // or substitutes an empty archive.
                break
            default:
                XCTFail("Expected missing authoritative archive, got \(error)")
            }
        }
        XCTAssertNotNil(storage.readBookmarkData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "CalcVaultTests-\(UUID().uuidString)"
        defaultsSuites.append(suiteName)
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }
}

private final class InMemoryBookmarkStorage: ArchiveBookmarkStorage {
    private var bookmark: Data?

    init(bookmark: Data?) {
        self.bookmark = bookmark
    }

    func readBookmarkData() -> Data? {
        bookmark
    }

    func writeBookmarkData(_ data: Data) throws {
        bookmark = data
    }
}

private struct SyntheticTarEntry {
    let name: String
    let payload: Data
    let typeFlag: UInt8

    init(name: String, payload: Data, typeFlag: UInt8 = 48) {
        self.name = name
        self.payload = payload
        self.typeFlag = typeFlag
    }
}

private func writeTar(entries: [SyntheticTarEntry], to url: URL) throws {
    var archive = Data()
    for entry in entries {
        var header = Data(repeating: 0, count: 512)
        writeField(entry.name, to: &header, range: 0..<100)
        writeField("0000644", to: &header, range: 100..<108)
        writeField("0000000", to: &header, range: 108..<116)
        writeField("0000000", to: &header, range: 116..<124)
        writeField(String(format: "%011llo", UInt64(entry.payload.count)), to: &header, range: 124..<136)
        writeField("00000000000", to: &header, range: 136..<148)
        header[156] = entry.typeFlag
        writeField("ustar", to: &header, range: 257..<263)
        writeField("00", to: &header, range: 263..<265)

        for index in 148..<156 { header[index] = 32 }
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        writeField(String(format: "%06llo", checksum) + "\0 ", to: &header, range: 148..<156)

        archive.append(header)
        archive.append(entry.payload)
        let remainder = entry.payload.count % 512
        if remainder != 0 { archive.append(Data(repeating: 0, count: 512 - remainder)) }
    }
    archive.append(Data(repeating: 0, count: 1_024))
    try archive.write(to: url, options: .atomic)
}

private func writeField(_ value: String, to data: inout Data, range: Range<Int>) {
    let bytes = Array(value.utf8)
    for (offset, byte) in bytes.prefix(range.count).enumerated() {
        data[range.lowerBound + offset] = byte
    }
}
