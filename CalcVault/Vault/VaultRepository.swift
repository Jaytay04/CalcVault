import Foundation

public struct VaultSessionPermit: Equatable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64

    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public typealias VaultSessionValidator = @Sendable (VaultSessionPermit) async -> Bool

public final class VaultSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var activePermit: VaultSessionPermit?

    public init() {}

    public func activate(_ permit: VaultSessionPermit) {
        lock.lock()
        activePermit = permit
        lock.unlock()
    }

    public func revoke() {
        lock.lock()
        activePermit = nil
        lock.unlock()
    }

    public func validate(_ permit: VaultSessionPermit) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activePermit == permit
    }
}

public final class VaultOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public enum VaultRepositoryState: Equatable, Sendable {
    case notInitialized
    case ready(itemCount: Int, generation: UInt64)
}

public enum VaultRepositoryCommitPoint: Sendable {
    case beforeObjectPublish
    case beforeManifestReplace
}

public protocol VaultInitializationPersisting: AnyObject, Sendable {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
}

extension UnlockedDeviceKeychainStore: VaultInitializationPersisting {}

public actor VaultRepository {
    public static let initializationAccount = "vault-storage-initialized-v1"

    private let rootDirectory: URL
    private let markerStore: VaultInitializationPersisting
    private let sessionValidator: VaultSessionValidator
    private let faultInjector: @Sendable (VaultRepositoryCommitPoint) throws -> Void
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64?
    private let fileManager: FileManager
    private let manifestCodec = VaultManifestCodec()
    private let encryptedStream = EncryptedStream()

    private var vaultDirectory: URL { rootDirectory.appendingPathComponent("vault", isDirectory: true) }
    private var objectsDirectory: URL { vaultDirectory.appendingPathComponent("objects", isDirectory: true) }
    private var stagingDirectory: URL { vaultDirectory.appendingPathComponent(".staging", isDirectory: true) }
    private var headerURL: URL { vaultDirectory.appendingPathComponent("vault.header") }
    private var manifestURL: URL { vaultDirectory.appendingPathComponent("manifest.cvm") }

    public init(
        rootDirectory: URL,
        markerStore: VaultInitializationPersisting = UnlockedDeviceKeychainStore(
            service: Phase2CredentialManager.metadataService
        ),
        fileManager: FileManager = .default,
        sessionValidator: @escaping VaultSessionValidator,
        faultInjector: @escaping @Sendable (VaultRepositoryCommitPoint) throws -> Void = { _ in },
        availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64? = { url in
            try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    ) {
        self.rootDirectory = rootDirectory
        self.markerStore = markerStore
        self.fileManager = fileManager
        self.sessionValidator = sessionValidator
        self.faultInjector = faultInjector
        self.availableCapacityProvider = availableCapacityProvider
    }

    public static func defaultRootDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw VaultFormatError.ioFailure("Application Support is unavailable.")
        }
        return applicationSupport
            .appendingPathComponent("CalcVaultVault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    public func state(
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit
    ) async throws -> VaultRepositoryState {
        try await requireValid(permit)
        guard let marker = try readMarker() else {
            if fileManager.fileExists(atPath: vaultDirectory.path) {
                throw VaultFormatError.inconsistentStorage
            }
            return .notInitialized
        }
        guard marker == vaultID else { throw VaultFormatError.identityMismatch }
        guard fileManager.fileExists(atPath: vaultDirectory.path) else {
            throw VaultFormatError.missingInitializedVault
        }
        let manifest = try loadValidatedManifest(rootKey: rootKey, vaultID: vaultID)
        try await requireValid(permit)
        return .ready(itemCount: manifest.items.count, generation: manifest.generation)
    }

    public func initialize(
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64
    ) async throws -> VaultManifest {
        try await requireValid(permit)
        guard try readMarker() == nil else { throw VaultFormatError.alreadyInitialized }
        guard !fileManager.fileExists(atPath: vaultDirectory.path) else {
            throw VaultFormatError.inconsistentStorage
        }
        let candidate = rootDirectory.appendingPathComponent(
            ".initialize-\(UUID().vaultFileComponent)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: candidate) }

        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try requestBackupExclusion(for: rootDirectory)
            try fileManager.createDirectory(
                at: candidate.appendingPathComponent("objects", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: candidate.appendingPathComponent(".staging", isDirectory: true),
                withIntermediateDirectories: true
            )
            let header = makeVaultHeader(vaultID: vaultID)
            let candidateHeader = candidate.appendingPathComponent("vault.header")
            try writeNewFile(header, to: candidateHeader)
            try applyCompleteProtection(to: candidateHeader)

            let manifest = VaultManifest(
                vaultID: vaultID,
                generation: 1,
                createdAtMilliseconds: nowMilliseconds,
                updatedAtMilliseconds: nowMilliseconds,
                items: []
            )
            let sealed = try manifestCodec.seal(manifest, rootKey: rootKey)
            let candidateManifest = candidate.appendingPathComponent("manifest.cvm")
            try writeNewFile(sealed, to: candidateManifest)
            try applyCompleteProtection(to: candidateManifest)
            _ = try manifestCodec.open(
                Data(contentsOf: candidateManifest, options: [.mappedIfSafe]),
                rootKey: rootKey,
                expectedVaultID: vaultID
            )
            try validateVaultHeader(Data(contentsOf: candidateHeader), expectedVaultID: vaultID)
            try await requireValid(permit)
            try fileManager.moveItem(at: candidate, to: vaultDirectory)
            try await requireValid(permit)

            // The marker is deliberately last. If this write fails, the
            // complete directory remains visible as inconsistent storage and
            // is never silently replaced or deleted.
            try markerStore.write(Data(vaultID.uuidString.lowercased().utf8), account: Self.initializationAccount)
            return manifest
        } catch let error as VaultFormatError {
            throw error
        } catch {
            throw VaultFormatError.ioFailure(error.localizedDescription)
        }
    }

    public func loadManifest(
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit
    ) async throws -> VaultManifest {
        try await requireValid(permit)
        guard let marker = try readMarker() else {
            throw fileManager.fileExists(atPath: vaultDirectory.path)
                ? VaultFormatError.inconsistentStorage
                : VaultFormatError.notInitialized
        }
        guard marker == vaultID else { throw VaultFormatError.identityMismatch }
        guard fileManager.fileExists(atPath: vaultDirectory.path) else {
            throw VaultFormatError.missingInitializedVault
        }
        let manifest = try loadValidatedManifest(rootKey: rootKey, vaultID: vaultID)
        for item in manifest.items where item.kind != .folder {
            guard let objectFileName = item.objectFileName,
                  fileManager.fileExists(
                    atPath: objectsDirectory.appendingPathComponent(objectFileName).path
                  ) else {
                throw VaultFormatError.missingInitializedVault
            }
        }
        try await requireValid(permit)
        return manifest
    }

    public func verifyObject(
        itemID: UUID,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit
    ) async throws {
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard let item = manifest.items.first(where: { $0.id == itemID }),
              item.kind != .folder,
              let objectFileName = item.objectFileName,
              let objectKey = item.objectKey else {
            throw VaultFormatError.invalidObject
        }
        let validatedLength = try encryptedStream.validate(
            sourceURL: objectsDirectory.appendingPathComponent(objectFileName),
            metadata: EncryptedObjectMetadata(
                vaultID: vaultID,
                objectID: item.id,
                revision: item.revision
            ),
            objectKey: objectKey
        )
        guard validatedLength == item.byteCount else {
            throw VaultFormatError.invalidObject
        }
        try await requireValid(permit)
    }

    /// Phase 3 storage primitive used with disposable fixtures. Phase 4 owns
    /// user-facing import policy, Photos handling, progress, and cancellation.
    public func commitObject(
        sourceURL: URL,
        displayName: String,
        kind: VaultItemKind,
        mediaType: String?,
        parentID: UUID? = nil,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64,
        progress: @escaping EncryptedStream.ProgressHandler = { _, _ in },
        cancellation: VaultOperationCancellation? = nil
    ) async throws -> VaultManifestItem {
        guard kind == .file || kind == .photo || kind == .video,
              (mediaType?.utf8.count ?? 0) <= VaultFormatV1.mediaTypeByteLimit else {
            throw VaultFormatError.invalidManifest
        }
        try validateName(displayName)
        var manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard manifest.items.count < VaultFormatV1.itemCountLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        guard manifest.generation < UInt64.max else {
            throw VaultFormatError.resourceLimitExceeded
        }
        try validateParent(parentID, in: manifest)
        try checkAvailableSpace(for: sourceURL)

        let objectID = UUID()
        let revision: UInt64 = 1
        let objectFileName = "\(objectID.vaultFileComponent).cvobj"
        let stagedObject = stagingDirectory.appendingPathComponent("\(UUID().vaultFileComponent).cvobj.tmp")
        let stagedManifest = stagingDirectory.appendingPathComponent("\(UUID().vaultFileComponent).manifest.tmp")
        defer {
            try? fileManager.removeItem(at: stagedObject)
            try? fileManager.removeItem(at: stagedManifest)
        }

        let metadata = EncryptedObjectMetadata(
            vaultID: vaultID,
            objectID: objectID,
            revision: revision
        )
        let encryption = try encryptedStream.encrypt(
            sourceURL: sourceURL,
            destinationURL: stagedObject,
            metadata: metadata,
            progress: progress,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        try applyCompleteProtection(to: stagedObject)
        let validatedLength = try encryptedStream.validate(
            sourceURL: stagedObject,
            metadata: metadata,
            objectKey: encryption.objectKey,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        guard validatedLength == encryption.plaintextLength else {
            throw VaultFormatError.invalidObject
        }
        try await requireValid(permit)
        try faultInjector(.beforeObjectPublish)
        try await requireValid(permit)

        let publishedObject = objectsDirectory.appendingPathComponent(objectFileName)
        guard !fileManager.fileExists(atPath: publishedObject.path) else {
            throw VaultFormatError.inconsistentStorage
        }
        try fileManager.moveItem(at: stagedObject, to: publishedObject)

        let item = VaultManifestItem(
            id: objectID,
            parentID: parentID,
            kind: kind,
            displayName: displayName,
            mediaType: mediaType,
            byteCount: encryption.plaintextLength,
            createdAtMilliseconds: nowMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            revision: revision,
            objectFileName: objectFileName,
            objectKey: encryption.objectKey
        )
        guard manifest.generation < UInt64.max else {
            throw VaultFormatError.resourceLimitExceeded
        }
        let nextGeneration = manifest.generation + 1
        manifest = VaultManifest(
            vaultID: manifest.vaultID,
            generation: nextGeneration,
            createdAtMilliseconds: manifest.createdAtMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            items: manifest.items + [item]
        )
        let sealed = try manifestCodec.seal(manifest, rootKey: rootKey)
        try writeNewFile(sealed, to: stagedManifest)
        try applyCompleteProtection(to: stagedManifest)
        _ = try manifestCodec.open(
            Data(contentsOf: stagedManifest, options: [.mappedIfSafe]),
            rootKey: rootKey,
            expectedVaultID: vaultID
        )
        try await requireValid(permit)
        try faultInjector(.beforeManifestReplace)
        try await requireValid(permit)
        try atomicallyReplaceManifest(with: stagedManifest)
        return item
    }

    public func createFolder(
        displayName: String,
        parentID: UUID? = nil,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64
    ) async throws -> VaultManifestItem {
        try validateName(displayName)
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard manifest.items.count < VaultFormatV1.itemCountLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        try validateParent(parentID, in: manifest)
        let item = VaultManifestItem(
            id: UUID(),
            parentID: parentID,
            kind: .folder,
            displayName: displayName,
            createdAtMilliseconds: nowMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            revision: 1
        )
        _ = try await publishManifest(
            current: manifest,
            items: manifest.items + [item],
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        return item
    }

    public func createNote(
        title: String,
        body: String,
        parentID: UUID? = nil,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64,
        cancellation: VaultOperationCancellation? = nil
    ) async throws -> VaultManifestItem {
        try validateName(title)
        guard body.utf8.count <= Int(VaultFormatV1.notePlaintextLimit) else {
            throw VaultFormatError.resourceLimitExceeded
        }
        let plaintext = Data(body.utf8)
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard manifest.items.count < VaultFormatV1.itemCountLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        try validateParent(parentID, in: manifest)
        let objectID = UUID()
        let revision: UInt64 = 1
        let stored = try await encryptAndPublishData(
            plaintext,
            objectID: objectID,
            revision: revision,
            vaultID: vaultID,
            permit: permit,
            cancellation: cancellation
        )
        let item = VaultManifestItem(
            id: objectID,
            parentID: parentID,
            kind: .note,
            displayName: title,
            mediaType: "text/plain; charset=utf-8",
            byteCount: stored.byteCount,
            createdAtMilliseconds: nowMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            revision: revision,
            objectFileName: stored.fileName,
            objectKey: stored.key
        )
        _ = try await publishManifest(
            current: manifest,
            items: manifest.items + [item],
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        return item
    }

    public func updateNote(
        itemID: UUID,
        title: String,
        body: String,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64,
        cancellation: VaultOperationCancellation? = nil
    ) async throws -> VaultManifestItem {
        try validateName(title)
        guard body.utf8.count <= Int(VaultFormatV1.notePlaintextLimit) else {
            throw VaultFormatError.resourceLimitExceeded
        }
        let plaintext = Data(body.utf8)
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard let index = manifest.items.firstIndex(where: { $0.id == itemID }),
              manifest.items[index].kind == .note else {
            throw VaultFormatError.itemNotFound
        }
        let previous = manifest.items[index]
        guard previous.revision < UInt64.max else { throw VaultFormatError.resourceLimitExceeded }
        let revision = previous.revision + 1
        let stored = try await encryptAndPublishData(
            plaintext,
            objectID: previous.id,
            revision: revision,
            vaultID: vaultID,
            permit: permit,
            cancellation: cancellation
        )
        let updated = VaultManifestItem(
            id: previous.id,
            parentID: previous.parentID,
            kind: .note,
            displayName: title,
            mediaType: "text/plain; charset=utf-8",
            byteCount: stored.byteCount,
            createdAtMilliseconds: previous.createdAtMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            revision: revision,
            objectFileName: stored.fileName,
            objectKey: stored.key,
            thumbnailID: previous.thumbnailID
        )
        var items = manifest.items
        items[index] = updated
        _ = try await publishManifest(
            current: manifest,
            items: items,
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        if let oldFileName = previous.objectFileName {
            try? fileManager.removeItem(at: objectsDirectory.appendingPathComponent(oldFileName))
        }
        return updated
    }

    public func renameItem(
        itemID: UUID,
        displayName: String,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64
    ) async throws -> VaultManifestItem {
        try validateName(displayName)
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard let index = manifest.items.firstIndex(where: { $0.id == itemID }) else {
            throw VaultFormatError.itemNotFound
        }
        let previous = manifest.items[index]
        let updated = replacing(
            previous,
            parentID: previous.parentID,
            displayName: displayName,
            updatedAtMilliseconds: nowMilliseconds
        )
        var items = manifest.items
        items[index] = updated
        _ = try await publishManifest(
            current: manifest,
            items: items,
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        return updated
    }

    public func moveItem(
        itemID: UUID,
        destinationParentID: UUID?,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64
    ) async throws -> VaultManifestItem {
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard let index = manifest.items.firstIndex(where: { $0.id == itemID }) else {
            throw VaultFormatError.itemNotFound
        }
        guard destinationParentID != itemID else { throw VaultFormatError.invalidManifest }
        try validateParent(destinationParentID, in: manifest)
        let previous = manifest.items[index]
        if previous.kind == .folder {
            try validateFolderMove(
                itemID: itemID,
                destinationParentID: destinationParentID,
                in: manifest
            )
        }
        let updated = replacing(
            previous,
            parentID: destinationParentID,
            displayName: previous.displayName,
            updatedAtMilliseconds: nowMilliseconds
        )
        var items = manifest.items
        items[index] = updated
        _ = try await publishManifest(
            current: manifest,
            items: items,
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        return updated
    }

    public func deleteItem(
        itemID: UUID,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        nowMilliseconds: Int64
    ) async throws {
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        guard let item = manifest.items.first(where: { $0.id == itemID }) else {
            throw VaultFormatError.itemNotFound
        }
        if item.kind == .folder,
           manifest.items.contains(where: { $0.parentID == itemID }) {
            throw VaultFormatError.folderNotEmpty
        }
        let items = manifest.items.filter { $0.id != itemID && $0.id != item.thumbnailID }
        _ = try await publishManifest(
            current: manifest,
            items: items,
            nowMilliseconds: nowMilliseconds,
            rootKey: rootKey,
            vaultID: vaultID,
            permit: permit
        )
        for removed in manifest.items where !items.contains(where: { $0.id == removed.id }) {
            if let objectFileName = removed.objectFileName {
                try? fileManager.removeItem(at: objectsDirectory.appendingPathComponent(objectFileName))
            }
        }
    }

    public func readItemData(
        itemID: UUID,
        maximumBytes: UInt64,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        cancellation: VaultOperationCancellation? = nil
    ) async throws -> Data {
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        let item = try objectItem(itemID, in: manifest)
        guard item.byteCount <= maximumBytes,
              let objectFileName = item.objectFileName,
              let objectKey = item.objectKey else {
            throw VaultFormatError.resourceLimitExceeded
        }
        let data = try encryptedStream.decryptToData(
            sourceURL: objectsDirectory.appendingPathComponent(objectFileName),
            metadata: EncryptedObjectMetadata(
                vaultID: vaultID,
                objectID: item.id,
                revision: item.revision
            ),
            objectKey: objectKey,
            maximumPlaintextLength: maximumBytes,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        try await requireValid(permit)
        return data
    }

    public func decryptItem(
        itemID: UUID,
        destinationURL: URL,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit,
        progress: @escaping EncryptedStream.ProgressHandler = { _, _ in },
        cancellation: VaultOperationCancellation? = nil
    ) async throws {
        let manifest = try await loadManifest(rootKey: rootKey, vaultID: vaultID, permit: permit)
        let item = try objectItem(itemID, in: manifest)
        guard let objectFileName = item.objectFileName,
              let objectKey = item.objectKey else {
            throw VaultFormatError.invalidObject
        }
        try checkAvailableSpace(requiredBytes: item.byteCount)
        try encryptedStream.decrypt(
            sourceURL: objectsDirectory.appendingPathComponent(objectFileName),
            destinationURL: destinationURL,
            metadata: EncryptedObjectMetadata(
                vaultID: vaultID,
                objectID: item.id,
                revision: item.revision
            ),
            objectKey: objectKey,
            progress: progress,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        try applyCompleteProtection(to: destinationURL)
        try requestBackupExclusion(for: destinationURL)
        try await requireValid(permit)
    }

    private func encryptAndPublishData(
        _ plaintext: Data,
        objectID: UUID,
        revision: UInt64,
        vaultID: UUID,
        permit: VaultSessionPermit,
        cancellation: VaultOperationCancellation?
    ) async throws -> (fileName: String, key: Data, byteCount: UInt64) {
        let fileName = "\(UUID().vaultFileComponent).cvobj"
        let stagedObject = stagingDirectory.appendingPathComponent("\(UUID().vaultFileComponent).cvobj.tmp")
        defer { try? fileManager.removeItem(at: stagedObject) }
        let metadata = EncryptedObjectMetadata(vaultID: vaultID, objectID: objectID, revision: revision)
        let result = try encryptedStream.encrypt(
            plaintext: plaintext,
            destinationURL: stagedObject,
            metadata: metadata,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        try applyCompleteProtection(to: stagedObject)
        let validatedLength = try encryptedStream.validate(
            sourceURL: stagedObject,
            metadata: metadata,
            objectKey: result.objectKey,
            shouldCancel: { cancellation?.isCancelled() ?? false }
        )
        guard validatedLength == result.plaintextLength else { throw VaultFormatError.invalidObject }
        try await requireValid(permit)
        try faultInjector(.beforeObjectPublish)
        try await requireValid(permit)
        let published = objectsDirectory.appendingPathComponent(fileName)
        guard !fileManager.fileExists(atPath: published.path) else {
            throw VaultFormatError.inconsistentStorage
        }
        try fileManager.moveItem(at: stagedObject, to: published)
        return (fileName, result.objectKey, result.plaintextLength)
    }

    private func publishManifest(
        current: VaultManifest,
        items: [VaultManifestItem],
        nowMilliseconds: Int64,
        rootKey: Data,
        vaultID: UUID,
        permit: VaultSessionPermit
    ) async throws -> VaultManifest {
        guard current.generation < UInt64.max else { throw VaultFormatError.resourceLimitExceeded }
        let next = VaultManifest(
            vaultID: current.vaultID,
            generation: current.generation + 1,
            createdAtMilliseconds: current.createdAtMilliseconds,
            updatedAtMilliseconds: nowMilliseconds,
            items: items
        )
        let staged = stagingDirectory.appendingPathComponent("\(UUID().vaultFileComponent).manifest.tmp")
        defer { try? fileManager.removeItem(at: staged) }
        let sealed = try manifestCodec.seal(next, rootKey: rootKey)
        try writeNewFile(sealed, to: staged)
        try applyCompleteProtection(to: staged)
        _ = try manifestCodec.open(
            Data(contentsOf: staged, options: [.mappedIfSafe]),
            rootKey: rootKey,
            expectedVaultID: vaultID
        )
        try await requireValid(permit)
        try faultInjector(.beforeManifestReplace)
        try await requireValid(permit)
        try atomicallyReplaceManifest(with: staged)
        return next
    }

    private func replacing(
        _ item: VaultManifestItem,
        parentID: UUID?,
        displayName: String,
        updatedAtMilliseconds: Int64
    ) -> VaultManifestItem {
        VaultManifestItem(
            id: item.id,
            parentID: parentID,
            kind: item.kind,
            displayName: displayName,
            mediaType: item.mediaType,
            byteCount: item.byteCount,
            createdAtMilliseconds: item.createdAtMilliseconds,
            updatedAtMilliseconds: updatedAtMilliseconds,
            revision: item.revision,
            objectFileName: item.objectFileName,
            objectKey: item.objectKey,
            thumbnailID: item.thumbnailID
        )
    }

    private func objectItem(_ itemID: UUID, in manifest: VaultManifest) throws -> VaultManifestItem {
        guard let item = manifest.items.first(where: { $0.id == itemID }),
              item.kind != .folder else {
            throw VaultFormatError.itemNotFound
        }
        return item
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= VaultFormatV1.displayNameByteLimit else {
            throw VaultFormatError.invalidName
        }
    }

    private func validateParent(_ parentID: UUID?, in manifest: VaultManifest) throws {
        guard let parentID else { return }
        guard manifest.items.first(where: { $0.id == parentID })?.kind == .folder else {
            throw VaultFormatError.itemNotFound
        }
    }

    private func validateFolderMove(
        itemID: UUID,
        destinationParentID: UUID?,
        in manifest: VaultManifest
    ) throws {
        var cursor = destinationParentID
        var visited: Set<UUID> = []
        while let current = cursor {
            guard current != itemID, visited.insert(current).inserted else {
                throw VaultFormatError.invalidManifest
            }
            cursor = manifest.items.first(where: { $0.id == current })?.parentID
        }
    }

    private func checkAvailableSpace(for sourceURL: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw VaultFormatError.ioFailure("The source size is unavailable.")
        }
        guard size <= VaultFormatV1.objectPlaintextLimit else {
            throw VaultFormatError.resourceLimitExceeded
        }
        try checkAvailableSpace(requiredBytes: size)
    }

    private func checkAvailableSpace(requiredBytes: UInt64) throws {
        if let available = try availableCapacityProvider(rootDirectory),
           available >= 0,
           UInt64(available) < requiredBytes + UInt64(VaultFormatV1.objectChunkSize * 4) {
            throw VaultFormatError.insufficientSpace
        }
    }

    private func loadValidatedManifest(rootKey: Data, vaultID: UUID) throws -> VaultManifest {
        guard fileManager.fileExists(atPath: headerURL.path),
              fileManager.fileExists(atPath: manifestURL.path) else {
            throw VaultFormatError.missingInitializedVault
        }
        try validateVaultHeader(Data(contentsOf: headerURL), expectedVaultID: vaultID)
        let sealed = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        return try manifestCodec.open(sealed, rootKey: rootKey, expectedVaultID: vaultID)
    }

    private func requireValid(_ permit: VaultSessionPermit) async throws {
        guard await sessionValidator(permit) else { throw VaultFormatError.staleSession }
    }

    private func readMarker() throws -> UUID? {
        guard let data = try markerStore.read(account: Self.initializationAccount) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8),
              text == text.lowercased(),
              let value = UUID(uuidString: text) else {
            throw VaultFormatError.inconsistentStorage
        }
        return value
    }

    private func makeVaultHeader(vaultID: UUID) -> Data {
        var data = Data()
        data.append(VaultFormatV1.vaultHeaderMagic)
        data.appendBigEndian(VaultFormatV1.version)
        data.appendBigEndian(UInt16(0))
        data.appendUUID(vaultID)
        return data
    }

    private func validateVaultHeader(_ data: Data, expectedVaultID: UUID) throws {
        guard data.count == VaultFormatV1.vaultHeaderLength else {
            throw VaultFormatError.malformedHeader
        }
        var reader = VaultBinaryReader(data)
        guard try reader.readData(count: 8) == VaultFormatV1.vaultHeaderMagic else {
            throw VaultFormatError.malformedHeader
        }
        let version: UInt16 = try reader.readInteger()
        guard version == VaultFormatV1.version else {
            throw VaultFormatError.unsupportedVersion(Int(version))
        }
        let reserved: UInt16 = try reader.readInteger()
        guard reserved == 0 else { throw VaultFormatError.malformedHeader }
        guard try reader.readUUID() == expectedVaultID else {
            throw VaultFormatError.identityMismatch
        }
    }

    private func writeNewFile(_ data: Data, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path),
              fileManager.createFile(atPath: url.path, contents: nil) else {
            throw VaultFormatError.ioFailure("A staging file could not be created.")
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func atomicallyReplaceManifest(with candidate: URL) throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw VaultFormatError.missingInitializedVault
        }
        _ = try fileManager.replaceItemAt(
            manifestURL,
            withItemAt: candidate,
            backupItemName: nil,
            options: []
        )
    }

    private func requestBackupExclusion(for url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func applyCompleteProtection(to url: URL) throws {
        try (url as NSURL).setResourceValue(
            FileProtectionType.complete,
            forKey: .fileProtectionKey
        )
    }
}
