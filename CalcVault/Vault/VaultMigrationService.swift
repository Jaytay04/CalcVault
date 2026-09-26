import Foundation

public enum VaultMigrationPoint: Sendable {
    case beforePublish
}

/// Transactional harness for future format migrations. Version 1 has no
/// supported predecessor, but every future migration must build and validate
/// a sibling candidate without mutating the current vault first.
public struct VaultMigrationService {
    private let fileManager: FileManager
    private let faultInjector: (VaultMigrationPoint) throws -> Void

    public init(
        fileManager: FileManager = .default,
        faultInjector: @escaping (VaultMigrationPoint) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.faultInjector = faultInjector
    }

    @discardableResult
    public func migrate(
        currentDirectory: URL,
        sourceVersion: Int,
        targetVersion: Int,
        buildCandidate: (_ current: URL, _ candidate: URL) throws -> Void,
        validateCandidate: (_ candidate: URL) throws -> Void
    ) throws -> URL {
        guard sourceVersion > 0,
              targetVersion > sourceVersion,
              fileManager.fileExists(atPath: currentDirectory.path) else {
            throw VaultFormatError.inconsistentStorage
        }
        let parent = currentDirectory.deletingLastPathComponent()
        let candidate = parent.appendingPathComponent(
            ".migration-\(UUID().vaultFileComponent)",
            isDirectory: true
        )
        let backupName = "vault.previous-v\(sourceVersion)-\(UUID().vaultFileComponent)"
        let backupURL = parent.appendingPathComponent(backupName, isDirectory: true)
        defer { try? fileManager.removeItem(at: candidate) }

        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        try buildCandidate(currentDirectory, candidate)
        try validateCandidate(candidate)
        try faultInjector(.beforePublish)
        _ = try fileManager.replaceItemAt(
            currentDirectory,
            withItemAt: candidate,
            backupItemName: backupName,
            options: []
        )
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw VaultFormatError.ioFailure("The previous vault was not retained after migration.")
        }
        return backupURL
    }
}
