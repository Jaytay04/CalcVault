import Foundation
import XCTest
@testable import CalcVault

final class VaultRepositoryTests: XCTestCase {
    func testExplicitInitializationAndEncryptedObjectCommit() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()

        let initialState = try await repository.state(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(initialState, .notInitialized)
        let initial = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        XCTAssertEqual(initial.generation, 1)
        XCTAssertEqual(initial.items, [])

        let source = fixture.baseDirectory.appendingPathComponent("synthetic-source.txt")
        let content = Data("disposable synthetic object body".utf8)
        try content.write(to: source)
        let item = try await repository.commitObject(
            sourceURL: source,
            displayName: "synthetic-private-name.txt",
            kind: .file,
            mediaType: "text/plain",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 200
        )
        try await repository.verifyObject(
            itemID: item.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        let manifest = try await repository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(manifest.generation, 2)
        XCTAssertEqual(manifest.items, [item])

        let vaultDirectory = fixture.rootDirectory.appendingPathComponent("vault", isDirectory: true)
        let persistentFiles = try recursiveFiles(in: vaultDirectory)
        XCTAssertFalse(persistentFiles.isEmpty)
        for url in persistentFiles {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data("synthetic-private-name.txt".utf8)), url.path)
            XCTAssertNil(bytes.range(of: content), url.path)
        }
    }

    func testMissingInitializedVaultFailsAndCannotBeReinitialized() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()
        _ = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )

        // This removes only a disposable test fixture. The persistent marker
        // intentionally remains so production behavior can be verified.
        try FileManager.default.removeItem(
            at: fixture.rootDirectory.appendingPathComponent("vault", isDirectory: true)
        )
        await XCTAssertThrowsErrorAsync(
            try await repository.state(
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .missingInitializedVault)
        }
        await XCTAssertThrowsErrorAsync(
            try await repository.initialize(
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 200
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .alreadyInitialized)
        }
    }

    func testInterruptedManifestCommitPreservesOldManifest() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let initialRepository = fixture.makeRepository()
        _ = try await initialRepository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        let source = fixture.baseDirectory.appendingPathComponent("source.bin")
        try Data("transaction fixture".utf8).write(to: source)

        let interrupted = fixture.makeRepository { point in
            if case .beforeManifestReplace = point { throw InjectedFailure() }
        }
        await XCTAssertThrowsErrorAsync(
            try await interrupted.commitObject(
                sourceURL: source,
                displayName: "never-published.txt",
                kind: .file,
                mediaType: "text/plain",
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 200
            )
        )

        let manifest = try await initialRepository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertTrue(manifest.items.isEmpty)
    }

    func testStaleSessionCannotPublishManifest() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let initialRepository = fixture.makeRepository()
        _ = try await initialRepository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        let source = fixture.baseDirectory.appendingPathComponent("source.bin")
        try Data("stale session fixture".utf8).write(to: source)

        let interrupted = fixture.makeRepository { point in
            if case .beforeManifestReplace = point {
                fixture.authority.invalidate()
            }
        }
        await XCTAssertThrowsErrorAsync(
            try await interrupted.commitObject(
                sourceURL: source,
                displayName: "stale.txt",
                kind: .file,
                mediaType: "text/plain",
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 200
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .staleSession)
        }
        fixture.authority.activate(fixture.permit)
        let manifest = try await initialRepository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertTrue(manifest.items.isEmpty)
    }

    func testFolderNoteRenameMoveUpdateAndDeleteRoundTrip() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()
        _ = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )

        let folder = try await repository.createFolder(
            displayName: "Synthetic folder",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 200
        )
        let note = try await repository.createNote(
            title: "Synthetic note",
            body: "Disposable note body",
            parentID: folder.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 300
        )
        let noteData = try await repository.readItemData(
            itemID: note.id,
            maximumBytes: VaultFormatV1.notePlaintextLimit,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(noteData, Data("Disposable note body".utf8))

        let updated = try await repository.updateNote(
            itemID: note.id,
            title: "Revised note",
            body: "Revised disposable body",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 400
        )
        XCTAssertEqual(updated.revision, 2)
        let renamed = try await repository.renameItem(
            itemID: folder.id,
            displayName: "Renamed folder",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 500
        )
        XCTAssertEqual(renamed.displayName, "Renamed folder")
        let moved = try await repository.moveItem(
            itemID: note.id,
            destinationParentID: nil,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 600
        )
        XCTAssertNil(moved.parentID)
        try await repository.deleteItem(
            itemID: folder.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 700
        )
        try await repository.deleteItem(
            itemID: note.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 800
        )
        let final = try await repository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertTrue(final.items.isEmpty)
        XCTAssertEqual(final.generation, 8)
    }

    func testNonemptyFolderDeletionAndLowDiskImportPreserveManifest() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()
        _ = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        let folder = try await repository.createFolder(
            displayName: "Folder",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 200
        )
        _ = try await repository.createNote(
            title: "Child",
            body: "body",
            parentID: folder.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 300
        )
        await XCTAssertThrowsErrorAsync(
            try await repository.deleteItem(
                itemID: folder.id,
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 400
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .folderNotEmpty)
        }

        let source = fixture.baseDirectory.appendingPathComponent("low-disk.bin")
        try Data(repeating: 0xaa, count: 1_024).write(to: source)
        let lowDiskRepository = fixture.makeRepository(availableCapacityProvider: { _ in 0 })
        await XCTAssertThrowsErrorAsync(
            try await lowDiskRepository.commitObject(
                sourceURL: source,
                displayName: "not-imported.bin",
                kind: .file,
                mediaType: "application/octet-stream",
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 500
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .insufficientSpace)
        }
        let manifest = try await repository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(manifest.items.count, 2)
        XCTAssertEqual(manifest.generation, 3)
    }

    func testFolderCannotMoveIntoDescendant() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()
        _ = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        let parent = try await repository.createFolder(
            displayName: "Parent",
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 200
        )
        let child = try await repository.createFolder(
            displayName: "Child",
            parentID: parent.id,
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 300
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.moveItem(
                itemID: parent.id,
                destinationParentID: child.id,
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 400
            )
        ) { error in
            XCTAssertEqual(error as? VaultFormatError, .invalidManifest)
        }
        let manifest = try await repository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertNil(manifest.items.first(where: { $0.id == parent.id })?.parentID)
        XCTAssertEqual(manifest.items.first(where: { $0.id == child.id })?.parentID, parent.id)
        XCTAssertEqual(manifest.generation, 3)
    }

    func testCancelledLargeImportPreservesCommittedManifest() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.cleanup() }
        let repository = fixture.makeRepository()
        _ = try await repository.initialize(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit,
            nowMilliseconds: 100
        )
        let source = fixture.baseDirectory.appendingPathComponent("cancel.bin")
        try Data(repeating: 0xbb, count: VaultFormatV1.objectChunkSize * 3).write(to: source)
        let cancellation = VaultOperationCancellation()

        await XCTAssertThrowsErrorAsync(
            try await repository.commitObject(
                sourceURL: source,
                displayName: "cancel.bin",
                kind: .file,
                mediaType: "application/octet-stream",
                rootKey: fixture.rootKey,
                vaultID: fixture.vaultID,
                permit: fixture.permit,
                nowMilliseconds: 200,
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
        let manifest = try await repository.loadManifest(
            rootKey: fixture.rootKey,
            vaultID: fixture.vaultID,
            permit: fixture.permit
        )
        XCTAssertEqual(manifest.generation, 1)
        XCTAssertTrue(manifest.items.isEmpty)
    }

    func testFailedMigrationPreservesPreviousDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-Migration-\(UUID().uuidString)", isDirectory: true)
        let current = directory.appendingPathComponent("vault", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let sentinel = current.appendingPathComponent("sentinel")
        try Data("previous-valid-vault".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try VaultMigrationService().migrate(
                currentDirectory: current,
                sourceVersion: 1,
                targetVersion: 2,
                buildCandidate: { _, candidate in
                    try Data("candidate".utf8).write(to: candidate.appendingPathComponent("sentinel"))
                },
                validateCandidate: { _ in throw InjectedFailure() }
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("previous-valid-vault".utf8))
    }

    private func recursiveFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }
    }
}

private struct InjectedFailure: Error {}

private final class MemoryVaultMarkerStore: VaultInitializationPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard values[account] == nil else {
            throw Phase2CredentialStoreError.duplicateItem
        }
        values[account] = data
    }
}

private final class TestSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var activePermit: VaultSessionPermit?

    init(permit: VaultSessionPermit) {
        activePermit = permit
    }

    func validate(_ permit: VaultSessionPermit) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activePermit == permit
    }

    func invalidate() {
        lock.lock()
        activePermit = nil
        lock.unlock()
    }

    func activate(_ permit: VaultSessionPermit) {
        lock.lock()
        activePermit = permit
        lock.unlock()
    }
}

private final class RepositoryFixture: @unchecked Sendable {
    let baseDirectory: URL
    let rootDirectory: URL
    let vaultID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let rootKey = Data(repeating: 0x42, count: 32)
    let permit = VaultSessionPermit(
        sessionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        generation: 7
    )
    let marker = MemoryVaultMarkerStore()
    let authority: TestSessionAuthority

    init() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcVault-Repository-\(UUID().uuidString)", isDirectory: true)
        rootDirectory = baseDirectory.appendingPathComponent("store", isDirectory: true)
        authority = TestSessionAuthority(permit: permit)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: false)
    }

    func makeRepository(
        faultInjector: @escaping @Sendable (VaultRepositoryCommitPoint) throws -> Void = { _ in },
        availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64? = { _ in nil }
    ) -> VaultRepository {
        VaultRepository(
            rootDirectory: rootDirectory,
            markerStore: marker,
            sessionValidator: { [authority] permit in authority.validate(permit) },
            faultInjector: faultInjector,
            availableCapacityProvider: availableCapacityProvider
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown")
    } catch {
        errorHandler(error)
    }
}
